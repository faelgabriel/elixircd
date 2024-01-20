defmodule ElixIRCd.Command.PingTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  doctest ElixIRCd.Command.Ping

  alias ElixIRCd.Command.Ping
  alias ElixIRCd.Message

  import ElixIRCd.Factory
  import Mimic

  describe "handle/2" do
    test "handles PING command with not enough parameters" do
      user = insert(:user)
      message = %Message{command: "PING", params: [], body: nil}

      Ping.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 461 #{user.nick} PING :Not enough parameters\r\n"}
      ])
    end

    test "handles PING command with body" do
      user = insert(:user)
      message = %Message{command: "PING", params: [], body: "anything"}

      Ping.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com PONG :anything\r\n"}
      ])
    end
  end
end
