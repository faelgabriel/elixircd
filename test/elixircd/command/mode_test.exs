defmodule ElixIRCd.Command.ModeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Mode
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles MODE command with user not registered" do
      Memento.transaction(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "MODE", params: ["#anything"]}

        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles MODE command with not enough parameters" do
      Memento.transaction(fn ->
        user = insert(:user)
        message = %Message{command: "MODE", params: []}

        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} MODE :Not enough parameters\r\n"}
        ])
      end)
    end

    # test "Future: handles MODE command for channel" do
    #   Memento.transaction(fn ->
    #     channel = insert(:channel)

    #     user = insert(:user)
    #     message = %Message{command: "MODE", params: [channel.name]}

    #     Mode.handle(user, message)
    #   end)
    # end

    # test "Future: handles MODE command for user" do
    #   Memento.transaction(fn ->
    #     user = insert(:user)
    #     message = %Message{command: "MODE", params: [user.nick]}

    #     Mode.handle(user, message)
    #   end)
    # end
  end
end
