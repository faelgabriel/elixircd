defmodule ElixIRCd.Commands.AwayTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Away
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users

  describe "handle/2" do
    test "handles AWAY command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "AWAY", params: ["#anything"]}

        assert :ok = Away.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles AWAY command with no message" do
      Memento.transaction!(fn ->
        user = insert(:user, away_message: "I'm away")
        message = %Message{command: "AWAY", params: []}

        assert :ok = Away.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 305 #{user.nick} :You are no longer marked as being away\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.away_message == nil
      end)
    end

    test "handles AWAY command with message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "AWAY", params: [], trailing: "I'm away"}

        assert :ok = Away.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 306 #{user.nick} :You have been marked as being away\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.away_message == "I'm away"
      end)
    end

    test "handles AWAY command with message exceeding maximum length" do
      max_away_length = 200

      Memento.transaction!(fn ->
        user = insert(:user)
        too_long_message = String.duplicate("a", max_away_length + 1)
        message = %Message{command: "AWAY", params: [], trailing: too_long_message}

        assert :ok = Away.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 417 #{user.nick} :Away message too long (maximum length: #{max_away_length} characters)\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.away_message == nil
      end)
    end
  end
end
