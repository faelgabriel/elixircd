defmodule ElixIRCd.Command.PingTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Ping
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles PING command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "PING", params: [], trailing: nil}

        assert :ok = Ping.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 461 #{user.nick} PING :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles PING command with trailing" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "PING", params: [], trailing: "anything"}

        assert :ok = Ping.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com PONG :anything\r\n"}
        ])
      end)
    end

    test "handles PING command with params" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "PING", params: ["anything"]}

        assert :ok = Ping.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com PONG anything\r\n"}
        ])
      end)
    end
  end
end
