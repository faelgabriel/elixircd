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

        assert_sent_messages_amount(user.socket, 4)
      end)
    end

    test "handles STATS command with supported query flag" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "STATS", params: ["u"]}

        Stats.handle(user, message)

        assert_sent_messages([
          {user.socket, ~r":server.example.com 242 #{user.nick} :Server Up 0 days, 00:00:\d{2}\r\n"},
          {user.socket, ":server.example.com 219 #{user.nick} u :End of /STATS report\r\n"}
        ])
      end)
    end

    test "handles STATS command with unsupported query flag" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "STATS", params: ["&"]}

        Stats.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 219 #{user.nick} & :End of /STATS report\r\n"}
        ])
      end)
    end
  end
end
