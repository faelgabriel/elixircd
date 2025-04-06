defmodule ElixIRCd.Commands.UsersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Commands.Users
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Metrics

  describe "handle/2" do
    test "handles USERS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "USERS", params: ["#anything"]}

        assert :ok = Users.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles USERS command" do
      Memento.transaction!(fn ->
        Metrics
        |> expect(:get, 1, fn :highest_connections -> 10 end)

        user = insert(:user)
        message = %Message{command: "USERS", params: []}

        assert :ok = Users.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 265 #{user.nick} 1 10 :Current local users 1, max 10\r\n"},
          {user.pid, ":irc.test 266 #{user.nick} 1 10 :Current global users 1, max 10\r\n"}
        ])
      end)
    end
  end
end
