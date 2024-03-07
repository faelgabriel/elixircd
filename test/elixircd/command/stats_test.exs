defmodule ElixIRCd.Command.StatsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Stats
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles STATS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "STATS", params: ["#anything"]}

        Stats.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles STATS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "STATS", params: []}

        Stats.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} STATS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles STATS command with query flag" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "STATS", params: ["a"]}

        Stats.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
