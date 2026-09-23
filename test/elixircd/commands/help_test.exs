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
        assert_sent_message_contains(user.pid, ":irc.test 704 #{user.nick} INDEX :ElixIRCd help index\r\n")
        assert_sent_message_contains(user.pid, ":irc.test 706 #{user.nick} INDEX :End of HELP\r\n")
      end
    end)
  end

  test "returns command help and reports unknown subjects" do
    Memento.transaction!(fn ->
      user = insert(:user)

      assert :ok = Help.handle(user, %Message{command: "HELP", params: ["PRIVMSG"]})

      assert_sent_messages([
        {user.pid,
         ":irc.test 704 #{user.nick} PRIVMSG :Sends a message after channel, silence, consent and target-limit checks.\r\n"},
        {user.pid, ":irc.test 705 #{user.nick} PRIVMSG :Syntax: PRIVMSG <target>[,<target>...] :<text>\r\n"},
        {user.pid, ":irc.test 705 #{user.nick} PRIVMSG :Use HELP INDEX to browse all commands and feature topics.\r\n"},
        {user.pid, ":irc.test 706 #{user.nick} PRIVMSG :End of HELP\r\n"}
      ])

      assert :ok = Help.handle(user, %Message{command: "HELP", params: ["missing"]})

      assert_sent_messages([
        {user.pid, ":irc.test 524 #{user.nick} MISSING :No help available\r\n"}
      ])
    end)
  end

  test "documents every dispatched command and advanced feature topics" do
    assert Map.keys(Help.command_topics()) |> Enum.sort() == ElixIRCd.Command.names()

    Memento.transaction!(fn ->
      user = insert(:user)
      assert :ok = Help.handle(user, %Message{command: "HELP", params: ["CHANNELMODES"]})
      assert_sent_message_contains(user.pid, ~r/ 705 .* \+U op-moderated, \+N blocks unprivileged nick changes/)
    end)
  end

  test "gates pre-registration help and links related operational topics" do
    Memento.transaction!(fn ->
      pending = insert(:user, registered: false)
      assert :ok = Help.handle(pending, %Message{command: "HELP", params: []})
      assert_sent_message_contains(pending.pid, ~r/ 451 \* :You have not registered/)

      user = insert(:user)

      for {subject, related} <- [
            {"MODE", "CHANNELMODES"},
            {"CHATHISTORY", "HISTORY"},
            {"METADATA", "METADATA"},
            {"CAP", "CAPABILITIES"}
          ] do
        assert :ok = Help.handle(user, %Message{command: "HELP", params: [subject]})
        assert_sent_message_contains(user.pid, ~r/#{related}/)
        Agent.update(@agent_name, fn _ -> [] end)
      end
    end)
  end
end
