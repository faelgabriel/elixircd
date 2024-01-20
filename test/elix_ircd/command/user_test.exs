defmodule ElixIRCd.Command.UserTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Command.User
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Handshake

  import ElixIRCd.Factory
  import Mimic

  describe "handle/2" do
    test "handles USER command with not enough parameters for user not registered" do
      user = insert(:user, identity: nil)

      message = %Message{command: "USER", params: []}
      User.handle(user, message)

      message = %Message{command: "USER", params: ["username"]}
      User.handle(user, message)

      message = %Message{command: "USER", params: ["username", "hostname"]}
      User.handle(user, message)

      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 461 * USER :Not enough parameters\r\n"},
        {user.socket, ":server.example.com 461 * USER :Not enough parameters\r\n"},
        {user.socket, ":server.example.com 461 * USER :Not enough parameters\r\n"}
      ])
    end

    test "handles USER command with valid and invalid parameters for user registered" do
      user = insert(:user)

      message = %Message{command: "USER", params: [], body: nil}
      User.handle(user, message)

      message = %Message{command: "USER", params: ["username", "hostname", "servername"], body: "real name"}
      User.handle(user, message)

      User.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 462 #{user.nick} :You may not reregister\r\n"},
        {user.socket, ":server.example.com 462 #{user.nick} :You may not reregister\r\n"}
      ])
    end

    test "handles USER command with valid parameters for user not registered" do
      Handshake
      |> expect(:handle, fn _user -> :ok end)

      user = insert(:user, identity: nil)
      message = %Message{command: "USER", params: ["username", "hostname", "servername"], body: "real name"}

      User.handle(user, message)
      verify!()

      assert_sent_messages([])
    end
  end
end
