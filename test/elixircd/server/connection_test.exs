defmodule ElixIRCd.Server.ConnectionTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Metrics
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
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
      assert :Z in user.modes
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
      assert :Z in user.modes
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

    test "handles max connections exceeded" do
      RateLimiter
      |> expect(:check_connection, fn {192, 168, 1, 3} ->
        {:error, :max_connections_exceeded}
      end)

      pid = self()

      assert :close = Connection.handle_connect(pid, :tcp, %{ip_address: {192, 168, 1, 3}, port_connected: 6667})
      assert [] = get_records(User)

      assert_sent_messages([
        {pid, ~r/\AERROR :Too many simultaneous connections from your IP address.\r\n/}
      ])
    end
  end

  describe "handle_receive/2" do
    setup do
      settings = Application.get_env(:elixircd, :settings)
      on_exit(fn -> Application.put_env(:elixircd, :settings, settings) end)
      Application.put_env(:elixircd, :settings, Keyword.put(settings, :utf8_only, true))
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

    test "aborts active SASL before closing a flooded connection" do
      user = insert(:user, registered: false)
      Memento.transaction!(fn -> SaslSessions.create(%{user_pid: user.pid, mechanism: "PLAIN", buffer: "partial"}) end)
      expect(RateLimiter, :check_message, fn _, _ -> {:error, :throttled_exceeded} end)
      reject(Command, :dispatch, 2)

      assert {:quit, "Excess flood"} = Connection.handle_receive(user.pid, "AUTHENTICATE payload")

      assert_sent_messages([
        {user.pid, ":irc.test 904 * :SASL authentication failed: Excess flood\r\n"},
        {user.pid, "ERROR :Excess flood\r\n"}
      ])

      Memento.transaction!(fn ->
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
        assert {:ok, %{registered: false}} = Users.get_by_pid(user.pid)
      end)
    end

    test "preserves labels on legacy throttling feedback" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      expect(RateLimiter, :check_message, fn _, _ -> {:error, :throttled, 2000} end)
      reject(Command, :dispatch, 2)

      assert :ok = Connection.handle_receive(user.pid, "@label=slow PRIVMSG #test :spam")
      assert_sent_message_contains(user.pid, ~r/^@label=slow :irc.test NOTICE .* :Please slow down\./)
      assert_sent_messages_amount(user.pid, 1)
    end

    test "throttled SETNAME returns the extension failure independently of negotiated capabilities" do
      caps = Application.get_env(:elixircd, :capabilities)
      config = Application.get_env(:elixircd, :rate_limiter)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, caps)
        Application.put_env(:elixircd, :rate_limiter, config)
      end)

      Application.put_env(:elixircd, :capabilities, Keyword.put(caps, :setname, true))

      overrides =
        Map.put(config[:message][:command_throttle], "SETNAME",
          capacity: 1,
          refill_rate: 0.001,
          cost: 1,
          window_ms: 60_000,
          disconnect_threshold: 10
        )

      Application.put_env(:elixircd, :rate_limiter, put_in(config, [:message, :command_throttle], overrides))

      for capabilities <- [[], ["setname"], ["setname", "standard-replies"]] do
        user = insert(:user, capabilities: capabilities ++ ["batch", "labeled-response"])
        assert :ok = Connection.handle_receive(user.pid, "@label=first SETNAME :Accepted")
        assert :ok = Connection.handle_receive(user.pid, "@label=second SETNAME :Rejected")

        assert_sent_message_contains(
          user.pid,
          ~r/^@label=second :irc.test FAIL SETNAME CANNOT_CHANGE_REALNAME :Please slow down\./
        )

        assert {:ok, updated} = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
        assert updated.realname == "Accepted"
        assert_sent_messages_amount(user.pid, 2)
      end
    end

    test "throttling does not enable SETNAME for unregistered users or when disabled" do
      caps = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, caps) end)
      stub(RateLimiter, :check_message, fn _, _ -> {:error, :throttled, 2000} end)
      reject(Command, :dispatch, 2)

      for {registered, enabled} <- [{false, true}, {true, false}] do
        Application.put_env(:elixircd, :capabilities, Keyword.put(caps, :setname, enabled))
        user = insert(:user, registered: registered, capabilities: ["standard-replies"])
        assert :ok = Connection.handle_receive(user.pid, "SETNAME :Rejected")
        assert_sent_message_contains(user.pid, ~r/^:irc.test NOTICE .* :Please slow down\./)
        assert_sent_messages_amount(user.pid, 1)
      end
    end

    test "sends snotice to operators with +s mode when flood occurs" do
      user = insert(:user)
      oper_with_s = insert(:user, modes: [:o, :s])

      RateLimiter
      |> expect(:check_message, fn target_user, "PRIVMSG #test :flood" ->
        assert target_user.pid == user.pid
        {:error, :throttled_exceeded}
      end)

      Command
      |> reject(:dispatch, 2)

      assert {:quit, "Excess flood"} = Connection.handle_receive(user.pid, "PRIVMSG #test :flood")

      user_info = "#{user.nick}!#{user.ident}@#{user.hostname} [127.0.0.1]"
      expected_snotice = ":irc.test NOTICE :*** Flood: Excess flood from #{user_info}\r\n"

      assert_sent_messages([
        {user.pid, ~r/\AERROR :Excess flood\r\n/},
        {oper_with_s.pid, expected_snotice}
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
         ":irc.test FAIL PRIVMSG INVALID_UTF8 :Message rejected, your IRC software MUST use UTF-8 encoding on this network\r\n"}
      ])
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
    end

    test "rejects invalid UTF-8 with one labeled FAIL and no state change" do
      reject(Command, :dispatch, 2)
      user = insert(:user, capabilities: ["standard-replies", "batch", "labeled-response"], realname: "Old")
      assert :ok = Connection.handle_receive(user.pid, "@label=utf8 SETNAME :" <> <<255>>)

      assert_sent_messages([
        {user.pid,
         "@label=utf8 :irc.test FAIL SETNAME INVALID_UTF8 :Message rejected, your IRC software MUST use UTF-8 encoding on this network\r\n"}
      ])

      Memento.transaction!(fn ->
        assert {:ok, %{realname: "Old"}} = Users.get_by_pid(user.pid)
      end)
    end

    test "rejects invalid UTF-8 before registration and recovers a command without label negotiation" do
      reject(Command, :dispatch, 2)
      user = insert(:user, registered: false, capabilities: [])
      Connection.handle_receive(user.pid, "@label=ignored user a b c :" <> <<255>>)

      assert_sent_messages([
        {user.pid,
         ":irc.test FAIL USER INVALID_UTF8 :Message rejected, your IRC software MUST use UTF-8 encoding on this network\r\n"}
      ])
    end

    test "uses a session reply for invalid UTF-8 with an unparseable command" do
      reject(Command, :dispatch, 2)

      for data <- [
            String.duplicate("A", 480) <> " :" <> <<255>>,
            <<255>>,
            "@" <> <<255>>
          ] do
        user = insert(:user, capabilities: ["standard-replies", "batch", "labeled-response"])
        Connection.handle_receive(user.pid, data)

        assert_sent_message_contains(
          user.pid,
          ":irc.test FAIL * INVALID_UTF8 :Message rejected, your IRC software MUST use UTF-8 encoding on this network\r\n"
        )

        assert_sent_messages_amount(user.pid, 1)
      end
    end

    test "ignores malformed and oversized labels on UTF-8 rejection without losing a valid command" do
      reject(Command, :dispatch, 2)

      for label <- [<<255>>, String.duplicate("x", 65)] do
        user = insert(:user, capabilities: ["standard-replies", "batch", "labeled-response"])
        Connection.handle_receive(user.pid, "@label=" <> label <> " PRIVMSG x :" <> <<255>>)

        assert_sent_message_contains(
          user.pid,
          ":irc.test FAIL PRIVMSG INVALID_UTF8 :Message rejected, your IRC software MUST use UTF-8 encoding on this network\r\n"
        )

        assert_sent_messages_amount(user.pid, 1)
      end
    end

    test "retains a valid label on UTF-8 rejection when the command cannot be relayed" do
      reject(Command, :dispatch, 2)
      user = insert(:user, capabilities: ["standard-replies", "batch", "labeled-response"])
      Connection.handle_receive(user.pid, "@label=invalid " <> <<255>>)

      assert_sent_messages([
        {user.pid,
         "@label=invalid :irc.test FAIL * INVALID_UTF8 :Message rejected, your IRC software MUST use UTF-8 encoding on this network\r\n"}
      ])
    end

    test "UTF-8 rejection preserves a negotiated label without standard-replies" do
      reject(Command, :dispatch, 2)
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      Connection.handle_receive(user.pid, "@label=legacy PRIVMSG x :" <> <<255>>)

      assert_sent_messages([
        {user.pid,
         "@label=legacy :irc.test FAIL PRIVMSG INVALID_UTF8 :Message rejected, your IRC software MUST use UTF-8 encoding on this network\r\n"}
      ])
    end

    test "rejects messages with too much tag data", %{user: user} do
      Command
      |> reject(:dispatch, 2)

      oversized_tags = String.duplicate("a", 4095)

      assert :ok = Connection.handle_receive(user.pid, "@#{oversized_tags} PRIVMSG #test :hello")

      assert_sent_messages([
        {user.pid, ":irc.test 417 #{user.nick} :Input line was too long\r\n"}
      ])
    end

    test "accepts the maximum client tag data length", %{user: user} do
      max_sized_tags = String.duplicate("a", 4094)

      Command
      |> expect(:dispatch, 1, fn dispatched_user, message ->
        assert dispatched_user.pid == user.pid
        assert message.tags == %{max_sized_tags => nil}
        :ok
      end)

      assert :ok = Connection.handle_receive(user.pid, "@#{max_sized_tags} PRIVMSG #test :hello")
      assert_sent_messages_amount(user.pid, 0)
    end

    test "accepts exactly 512 wire bytes independently of the tag budget", %{user: user} do
      body = "PRIVMSG #test :" <> String.duplicate("a", 495)
      assert byte_size(body) == 510
      tags = "@" <> String.duplicate("a", 4094) <> " "

      expect(Command, :dispatch, 6, fn _, message ->
        assert message.command == "PRIVMSG"
        :ok
      end)

      for prefix <- ["", tags], ending <- ["", "\n", "\r\n"] do
        assert :ok = Connection.handle_receive(user.pid, prefix <> body <> ending)
      end

      assert_sent_messages_amount(user.pid, 0)
    end

    test "rejects oversized message bodies before parsing or broadcasting", %{user: user} do
      reject(Command, :dispatch, 2)

      for input <- [
            String.duplicate("x", 511),
            "PRIVMSG #test :" <> String.duplicate("é", 249),
            "@a=b " <> String.duplicate("x", 511) <> "\r\n",
            String.duplicate("x", 1_000_000)
          ] do
        assert :ok = Connection.handle_receive(user.pid, input)
        assert_sent_messages([{user.pid, ":irc.test 417 #{user.nick} :Input line was too long\r\n"}])
      end
    end

    test "applies flood protection to oversized messages", %{user: user} do
      input = "PRIVMSG #test :" <> String.duplicate("x", 510)
      expect(RateLimiter, :check_message, fn ^user, ^input -> {:error, :throttled_exceeded} end)
      reject(Command, :dispatch, 2)

      assert {:quit, "Excess flood"} = Connection.handle_receive(user.pid, input)
      assert_sent_messages([{user.pid, "ERROR :Excess flood\r\n"}])
    end

    test "prioritizes the tag data limit for malformed messages", %{user: user} do
      Command
      |> reject(:dispatch, 2)

      oversized_tags = String.duplicate("a", 4095)

      assert :ok = Connection.handle_receive(user.pid, "@#{oversized_tags}")

      assert_sent_messages([
        {user.pid, ":irc.test 417 #{user.nick} :Input line was too long\r\n"}
      ])
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
    test "classifies operational close reasons without using the client supplied reason as a metric label" do
      test_pid = self()
      handler = "connection-close-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:elixircd, :connection, :closed],
          fn _event, _measurements, metadata, _config ->
            send(test_pid, {:closed, metadata.reason})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      for {wire_reason, metric_reason} <- [
            {"Connection Timeout", :timeout},
            {"Connection Error", :transport_error},
            {"Server Shutdown", :shutdown},
            {"Excess flood", :rate_limit},
            {"Connection Closed", :client_closed}
          ] do
        user = insert(:user)
        assert :ok = Connection.handle_disconnect(user.pid, user.transport, wire_reason)
        assert_received {:closed, ^metric_reason}
      end
    end

    test "handles disconnect successfully for user not registered" do
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

    test "sends snotice to operators with +s mode when user quits" do
      user = insert(:user)
      oper_with_s = insert(:user, modes: [:o, :s])

      assert :ok = Connection.handle_disconnect(user.pid, user.transport, "Client quit")

      user_info = "#{user.nick}!#{user.ident}@#{user.hostname} [127.0.0.1]"
      expected_snotice = ":irc.test NOTICE :*** Quit: Client exiting: #{user_info} (Client quit)\r\n"

      assert_sent_messages([
        {oper_with_s.pid, expected_snotice}
      ])
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
