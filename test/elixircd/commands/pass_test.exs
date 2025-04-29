defmodule ElixIRCd.Commands.PassTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Commands.Pass
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users

  import ElixIRCd.Factory

  describe "handle/2" do
    test "handles PASS command with user registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: true)
        message = %Message{command: "PASS", params: ["password"]}

        assert :ok = Pass.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"}
        ])
      end)
    end

    test "handles PASS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "PASS", params: []}

        assert :ok = Pass.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 * PASS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles PASS command with a password" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "PASS", params: ["password"]}

        assert :ok = Pass.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.password == "password"
      end)
    end
  end
end
