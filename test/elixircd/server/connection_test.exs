defmodule ElixIRCd.Server.ConnectionTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Metrics
  alias ElixIRCd.Server.Connection
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
  end

  describe "handle_recv/2" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "handles valid packet", %{user: user} do
      Command
      |> expect(:dispatch, 1, fn dispatched_user, message ->
        assert dispatched_user.pid == user.pid
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      assert :ok = Connection.handle_recv(user.pid, "COMMAND test")
    end

    test "handles empty packets", %{user: user} do
      Command
      |> reject(:dispatch, 2)

      assert :ok = Connection.handle_recv(user.pid, "\r\n")
      assert :ok = Connection.handle_recv(user.pid, "  \r\n")
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
