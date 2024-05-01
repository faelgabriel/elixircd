defmodule ElixIRCd.Command.WallopsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Command.Wallops
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WALLOPS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WALLOPS", params: ["#anything"]}

        Wallops.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WALLOPS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WALLOPS", params: []}

        Wallops.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} WALLOPS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WALLOPS command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WALLOPS", params: [], trailing: "message"}

        Wallops.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handle WALLOPS command with user operator and message" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        target_user = insert(:user, modes: ["w"])
        message = %Message{command: "WALLOPS", params: [], trailing: "Wallops message"}

        Wallops.handle(user, message)

        assert_sent_messages([
          {target_user.socket, ":#{build_user_mask(user)} WALLOPS :Wallops message\r\n"}
        ])
      end)
    end
  end
end
