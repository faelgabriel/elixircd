defmodule ElixIRCd.Commands.WallopsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Wallops
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WALLOPS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WALLOPS", params: ["#anything"]}

        assert :ok = Wallops.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WALLOPS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WALLOPS", params: []}

        assert :ok = Wallops.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} WALLOPS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WALLOPS command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WALLOPS", params: [], trailing: "message"}

        assert :ok = Wallops.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handle WALLOPS command with user operator and message" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        target_user = insert(:user, modes: ["w"])
        message = %Message{command: "WALLOPS", params: [], trailing: "Wallops message"}

        assert :ok = Wallops.handle(user, message)

        assert_sent_messages([
          {target_user.pid, ":#{user_mask(user)} WALLOPS :Wallops message\r\n"}
        ])
      end)
    end
  end
end
