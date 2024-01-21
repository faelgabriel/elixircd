defmodule ElixIRCd.Command.NickTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  doctest ElixIRCd.Command.Nick

  alias ElixIRCd.Command.Nick
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Handshake

  import ElixIRCd.Factory
  import Mimic

  describe "handle/2" do
    test "handles NICK command with not enough parameters" do
      user = insert(:user)
      message = %Message{command: "NICK", params: []}

      Nick.handle(user, message)

      assert_sent_messages([
        {user.socket, ":server.example.com 461 #{user.nick} NICK :Not enough parameters\r\n"}
      ])
    end

    test "handles NICK command with invalid nick" do
      user = insert(:user)
      message = %Message{command: "NICK", params: ["invalid.nick"]}

      Nick.handle(user, message)

      assert_sent_messages([
        {user.socket, ":server.example.com 432 * invalid.nick :Nickname is unavailable: Illegal characters\r\n"}
      ])
    end

    test "handles NICK command with valid nick already in use" do
      user = insert(:user)
      insert(:user, nick: "existing")
      message = %Message{command: "NICK", params: ["existing"]}

      Nick.handle(user, message)

      assert_sent_messages([
        {user.socket, ":server.example.com 433 #{user.nick} existing :Nickname is already in use\r\n"}
      ])
    end

    test "handles NICK command with valid nick for user registered" do
      user = insert(:user)
      message = %Message{command: "NICK", params: ["new_nick"]}

      Nick.handle(user, message)

      assert_sent_messages([{user.socket, ":#{user.identity} NICK new_nick\r\n"}])
    end

    test "handles NICK command with valid nick for user not registered" do
      Handshake
      |> expect(:handle, fn _user -> :ok end)

      user = insert(:user, identity: nil)
      message = %Message{command: "NICK", params: ["new_nick"]}

      Nick.handle(user, message)

      assert_sent_messages([])
    end

    test "handles NICK command with nick passed as body" do
      user = insert(:user)
      message = %Message{command: "NICK", params: [], body: "new_nick"}

      Nick.handle(user, message)

      assert_sent_messages([{user.socket, ":#{user.identity} NICK new_nick\r\n"}])
    end
  end
end
