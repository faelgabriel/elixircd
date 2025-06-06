defmodule ElixIRCd.Server.ConnectionTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Metrics
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.RateLimiter
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  describe "handle_connect/3" do
    test "handles successful tcp connection" do
      assert :ok = Connection.handle_connect(self(), :tcp, %{ip_address: {127, 0, 0, 1}, port_connected: 6667})

      assert [%User{} = user] = get_records(User)
      assert user.pid == self()
      assert user.transport == :tcp
      assert user.ip_address == {127, 0, 0, 1}
      assert user.port_connected == 6667
      assert user.modes == []
    end

    test "handles successful tls connection" do
      assert :ok = Connection.handle_connect(self(), :tls, %{ip_address: {127, 0, 0, 1}, port_connected: 6697})

      assert [%User{} = user] = get_records(User)
      assert user.pid == self()
      assert user.transport == :tls
      assert user.ip_address == {127, 0, 0, 1}
      assert user.port_connected == 6697
      assert "Z" in user.modes
    end

    test "handles successful ws connection" do
      assert :ok = Connection.handle_connect(self(), :ws, %{ip_address: {127, 0, 0, 1}, port_connected: 6667})

      assert [%User{} = user] = get_records(User)
      assert user.pid == self()
      assert user.transport == :ws
      assert user.ip_address == {127, 0, 0, 1}
      assert user.port_connected == 6667
      assert user.modes == []
    end

    test "handles successful wss connection" do
      assert :ok = Connection.handle_connect(self(), :wss, %{ip_address: {127, 0, 0, 1}, port_connected: 6697})

      assert [%User{} = user] = get_records(User)
      assert user.pid == self()
      assert user.transport == :wss
      assert user.ip_address == {127, 0, 0, 1}
      assert user.port_connected == 6697
      assert "Z" in user.modes
    end

    test "updates connection stats" do
      pid1 = self()
      pid2 = spawn(fn -> :ok end)

      assert :ok = Connection.handle_connect(pid1, :tcp, %{ip_address: {127, 0, 0, 1}, port_connected: 6667})
      assert :ok = Connection.handle_connect(pid2, :tcp, %{ip_address: {127, 0, 0, 1}, port_connected: 6667})

      assert Metrics.get(:total_connections) == 2
      assert Metrics.get(:highest_connections) == 2
    end

    test "handles rate limited connection with throttled error" do
      RateLimiter
      |> expect(:check_connection, fn {192, 168, 1, 1} ->
        {:error, :throttled, 5000}
      end)

      pid = self()

      assert :close = Connection.handle_connect(pid, :tcp, %{ip_address: {192, 168, 1, 1}, port_connected: 6667})
      assert [] = get_records(User)

      assert_sent_messages([
        {pid, ~r/\AERROR :Too many connections from your IP address. Try again in \d+ seconds.\r\n/}
      ])
    end

    test "handles rate limited connection with exceeded threshold" do
      RateLimiter
      |> expect(:check_connection, fn {192, 168, 1, 2} ->
        {:error, :throttled_exceeded}
      end)

      pid = self()

      assert :close = Connection.handle_connect(pid, :tcp, %{ip_address: {192, 168, 1, 2}, port_connected: 6667})
      assert [] = get_records(User)

      assert_sent_messages_amount(pid, 0)
    end
  end

  describe "handle_receive/2" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "handles message when user not found" do
      Command
      |> reject(:dispatch, 2)

      assert :ok = Connection.handle_receive(self(), "PRIVMSG #test :hello")
    end

    test "handles valid packet", %{user: user} do
      Command
      |> expect(:dispatch, 1, fn dispatched_user, message ->
        assert dispatched_user.pid == user.pid
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      assert :ok = Connection.handle_receive(user.pid, "COMMAND test")
    end

    test "handles empty packets", %{user: user} do
      Command
      |> reject(:dispatch, 2)

      assert :ok = Connection.handle_receive(user.pid, "\r\n")
      assert :ok = Connection.handle_receive(user.pid, "  \r\n")
    end

    test "handles rate limited message with throttled error", %{user: user} do
      RateLimiter
      |> expect(:check_message, fn target_user, "PRIVMSG #test :spam" ->
        assert target_user.pid == user.pid
        {:error, :throttled, 2000}
      end)

      Command
      |> reject(:dispatch, 2)

      assert :ok = Connection.handle_receive(user.pid, "PRIVMSG #test :spam")

      assert_sent_messages([
        {user.pid,
         ~r/\A:irc.test NOTICE #{user.nick} :Please slow down. You are sending messages too fast. Try again in \d+ seconds.\r\n/}
      ])
    end

    test "handles rate limited message with exceeded threshold", %{user: user} do
      RateLimiter
      |> expect(:check_message, fn target_user, "PRIVMSG #test :flood" ->
        assert target_user.pid == user.pid
        {:error, :throttled_exceeded}
      end)

      Command
      |> reject(:dispatch, 2)

      assert {:quit, "Excess flood"} = Connection.handle_receive(user.pid, "PRIVMSG #test :flood")

      assert_sent_messages([
        {user.pid, ~r/\AERROR :Excess flood\r\n/}
      ])
    end

    test "handles valid UTF-8 message when utf8_only is enabled", %{user: user} do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: true))

      Command
      |> expect(:dispatch, 1, fn dispatched_user, message ->
        assert dispatched_user.pid == user.pid
        assert message == %Message{command: "PRIVMSG", params: ["#test"], trailing: "Hello world! 🌍"}
        :ok
      end)

      assert :ok = Connection.handle_receive(user.pid, "PRIVMSG #test :Hello world! 🌍")

      Application.put_env(:elixircd, :settings, original_settings)
    end

    test "handles invalid UTF-8 message when utf8_only is enabled", %{user: user} do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: true))

      Command
      |> reject(:dispatch, 2)

      # Create an invalid UTF-8 string by using a binary with invalid UTF-8 bytes
      invalid_utf8_message = "PRIVMSG #test :" <> <<0xFF, 0xFE>>

      assert :ok = Connection.handle_receive(user.pid, invalid_utf8_message)

      assert_sent_messages([
        {user.pid,
         ":irc.test NOTICE #{user.nick} :Message rejected, your IRC software MUST use UTF-8 encoding on this network\r\n"}
      ])

      Application.put_env(:elixircd, :settings, original_settings)
    end

    test "allows invalid UTF-8 message when utf8_only is disabled", %{user: user} do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: false))

      Command
      |> expect(:dispatch, 1, fn dispatched_user, _message ->
        assert dispatched_user.pid == user.pid
        :ok
      end)

      # Create an invalid UTF-8 string by using a binary with invalid UTF-8 bytes
      invalid_utf8_message = "PRIVMSG #test :" <> <<0xFF, 0xFE>>

      assert :ok = Connection.handle_receive(user.pid, invalid_utf8_message)

      # Should not send any error messages
      assert_sent_messages_amount(user.pid, 0)

      Application.put_env(:elixircd, :settings, original_settings)
    end
  end

  describe "handle_send/2" do
    @tag :skip_message_agent
    test "sends a {:broadcast, data} message to the given pid" do
      assert :ok = Connection.handle_send(self(), "hello")
      assert_received {:broadcast, "hello"}
    end
  end

  describe "handle_disconnect/3" do
    test "handles disconnect successfully for unregistered user" do
      user = insert(:user, registered: false)

      assert :ok = Connection.handle_disconnect(user.pid, user.transport, "Test disconnect")

      assert [] = get_records(User)
    end

    test "handles disconnect successfully when user is a member of a channel with no other users" do
      user = insert(:user)
      channel = insert(:channel)
      insert(:channel_invite, user: user, channel: channel)
      insert(:user_channel, user: user, channel: channel)

      assert :ok = Connection.handle_disconnect(user.pid, user.transport, "Test disconnect")

      assert [] = get_records(User)
      assert [] = get_records(Channel)
      assert [] = get_records(ChannelInvite)
      assert [] = get_records(UserChannel)

      assert [historical_user] = get_records(HistoricalUser)
      assert historical_user.nick_key == user.nick_key
      assert historical_user.nick == user.nick
      assert historical_user.hostname == user.hostname
      assert historical_user.ident == user.ident
      assert historical_user.realname == user.realname
    end

    test "handles disconnect successfully when user is a member of a channel with other users" do
      user = insert(:user)
      channel = insert(:channel)
      insert(:channel_invite, user: user, channel: channel)
      insert(:user_channel, user: user, channel: channel)

      other_user = insert(:user)
      other_user_channel = insert(:user_channel, user: other_user, channel: channel)

      assert :ok = Connection.handle_disconnect(user.pid, user.transport, "Test disconnect")

      assert [] = get_records(ChannelInvite)
      assert [^channel] = get_records(Channel)
      assert [^other_user] = get_records(User)
      assert [^other_user_channel] = get_records(UserChannel)
    end

    test "handles user not found error" do
      assert :ok = Connection.handle_disconnect(self(), :tcp, "Test disconnect")
    end
  end

  @spec get_records(struct()) :: [struct()]
  defp get_records(table) do
    Memento.transaction!(fn -> Memento.Query.all(table) end)
  end
end
