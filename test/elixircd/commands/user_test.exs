defmodule ElixIRCd.Commands.UserTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.User
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Handshake

  describe "handle/2" do
    test "handles USER command with not enough parameters for user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        message = %Message{command: "USER", params: []}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username"]}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username", "0"]}
        assert :ok = User.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 * USER :Not enough parameters\r\n"},
          {user.pid, ":irc.test 461 * USER :Not enough parameters\r\n"},
          {user.pid, ":irc.test 461 * USER :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles USER command with valid and invalid parameters for user registered" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "USER", params: [], trailing: nil}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username", "0", "*"], trailing: "real name"}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username", "0", "*", "realname"]}
        assert :ok = User.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"},
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"},
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"}
        ])
      end)
    end

    test "handles USER command with valid parameters for user not registered" do
      Handshake
      |> expect(:handle, 2, fn _user -> :ok end)

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        message = %Message{command: "USER", params: ["username", "0", "*"], trailing: "real name"}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username", "0", "*", "realname"]}
        assert :ok = User.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
