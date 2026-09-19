defmodule ElixIRCd.Commands.HelpTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Help
  alias ElixIRCd.Message

  test "returns an indexed help response for HELP and HELPOP" do
    Memento.transaction!(fn ->
      user = insert(:user)

      for command <- ["HELP", "HELPOP"] do
        assert :ok = Help.handle(user, %Message{command: command, params: []})
        assert_sent_message_contains(user.pid, ":irc.test 704 #{user.nick} INDEX :ElixIRCd command index\r\n")
        assert_sent_message_contains(user.pid, ":irc.test 706 #{user.nick} INDEX :End of HELP\r\n")
      end
    end)
  end

  test "returns command help and reports unknown subjects" do
    Memento.transaction!(fn ->
      user = insert(:user)

      assert :ok = Help.handle(user, %Message{command: "HELP", params: ["PRIVMSG"]})

      assert_sent_messages([
        {user.pid, ":irc.test 704 #{user.nick} PRIVMSG :PRIVMSG is supported by this server\r\n"},
        {user.pid,
         ":irc.test 705 #{user.nick} PRIVMSG :Use standard IRC syntax and consult the Modern IRC specification for parameters.\r\n"},
        {user.pid, ":irc.test 706 #{user.nick} PRIVMSG :End of HELP\r\n"}
      ])

      assert :ok = Help.handle(user, %Message{command: "HELP", params: ["missing"]})

      assert_sent_messages([
        {user.pid, ":irc.test 524 #{user.nick} MISSING :No help available\r\n"}
      ])
    end)
  end
end
