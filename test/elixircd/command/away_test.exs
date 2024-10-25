defmodule ElixIRCd.Command.AwayTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Away
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users

  describe "handle/2" do
    test "handles AWAY command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "AWAY", params: ["#anything"]}

        assert :ok = Away.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles AWAY command with no message" do
      Memento.transaction!(fn ->
        user = insert(:user, away_message: "I'm away")
        message = %Message{command: "AWAY", params: []}

        assert :ok = Away.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 305 #{user.nick} :You are no longer marked as being away\r\n"}
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
          {user.socket, ":server.example.com 306 #{user.nick} :You have been marked as being away\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.away_message == "I'm away"
      end)
    end
  end
end
