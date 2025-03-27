defmodule ElixIRCd.Commands.StatsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Commands.Stats
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Metrics

  describe "handle/2" do
    test "handles STATS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "STATS", params: ["#anything"]}

        assert :ok = Stats.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles STATS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "STATS", params: []}

        assert :ok = Stats.handle(user, message)

        assert_sent_messages_amount(user.pid, 4)
      end)
    end

    test "handles STATS command with supported query flag" do
      Memento.transaction!(fn ->
        DateTime
        |> expect(:diff, 1, fn _, _ -> 999_969 end)

        Metrics
        |> expect(:get, 1, fn :highest_connections -> 10 end)
        |> expect(:get, 1, fn :total_connections -> 50 end)

        user = insert(:user)
        message = %Message{command: "STATS", params: ["u"]}

        assert :ok = Stats.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 242 #{user.nick} :Server Up 11 days, 13:46:09\r\n"},
          {user.pid,
           ":server.example.com 250 #{user.nick} :Highest connection count: 10 (1 clients) (50 connections received)\r\n"},
          {user.pid, ":server.example.com 219 #{user.nick} u :End of /STATS report\r\n"}
        ])
      end)
    end

    test "handles STATS command with unsupported query flag" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "STATS", params: ["&"]}

        assert :ok = Stats.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 219 #{user.nick} & :End of /STATS report\r\n"}
        ])
      end)
    end
  end
end
