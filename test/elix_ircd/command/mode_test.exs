defmodule ElixIRCd.Command.ModeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  doctest ElixIRCd.Command.Mode

  alias ElixIRCd.Command.Mode
  alias ElixIRCd.Message

  import ElixIRCd.Factory
  import Mimic

  describe "handle/2" do
    test "handles MODE command with user not registered" do
      user = insert(:user, identity: nil)
      message = %Message{command: "MODE", params: ["#anything"]}

      Mode.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
      ])
    end

    test "handles MODE command with not enough parameters" do
      user = insert(:user)
      message = %Message{command: "MODE", params: []}

      Mode.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 461 #{user.nick} MODE :Not enough parameters\r\n"}
      ])
    end

    test "Future: handles MODE command for channel" do
      channel = insert(:channel)

      user = insert(:user)
      message = %Message{command: "MODE", params: [channel.name]}

      Mode.handle(user, message)
      verify!()
    end

    test "Future: handles MODE command for user" do
      user = insert(:user)
      message = %Message{command: "MODE", params: [user.nick]}

      Mode.handle(user, message)
      verify!()
    end
  end
end
