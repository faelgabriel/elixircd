defmodule ElixIRCd.Commands.LusersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Lusers
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Metrics

  describe "handle/2" do
    test "handles LUSERS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "LUSERS", params: ["#anything"]}

        assert :ok = Lusers.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles LUSERS command" do
      Memento.transaction!(fn ->
        Metrics
        |> expect(:get, 1, fn :highest_connections -> 10 end)

        insert(:user, registered: true, modes: [])
        insert(:user, registered: true, modes: ["i"])
        insert(:user, registered: true, modes: ["o"])
        insert(:user, registered: false)

        user = insert(:user)
        message = %Message{command: "LUSERS", params: []}

        assert :ok = Lusers.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 251 #{user.nick} :There are 3 users and 1 invisible on 1 server\r\n"},
          {user.pid, ":irc.test 252 #{user.nick} 1 :operator(s) online\r\n"},
          {user.pid, ":irc.test 253 #{user.nick} 1 :unknown connection(s)\r\n"},
          {user.pid, ":irc.test 254 #{user.nick} 0 :channels formed\r\n"},
          {user.pid, ":irc.test 255 #{user.nick} :I have 5 clients and 0 servers\r\n"},
          {user.pid, ":irc.test 265 #{user.nick} 5 10 :Current local users 5, max 10\r\n"},
          {user.pid, ":irc.test 266 #{user.nick} 5 10 :Current global users 5, max 10\r\n"}
        ])
      end)
    end
  end
end
