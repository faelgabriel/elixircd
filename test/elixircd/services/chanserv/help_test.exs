defmodule ElixIRCd.Services.Chanserv.HelpTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Help

  describe "handle/2" do
    test "handles HELP command with no parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP"])

        assert_sent_messages_amount(user.pid, 32)
      end)
    end

    test "handles main command help topics" do
      commands = [
        "REGISTER",
        "DROP",
        "INFO",
        "TRANSFER",
        "ACCESS",
        "FLAGS",
        "ALIST",
        "STATUS",
        "KICK",
        "BAN",
        "UNBAN",
        "INVITE",
        "TOPIC",
        "SYNC",
        "CLEAR",
        "OP",
        "DEOP",
        "VOICE",
        "DEVOICE"
      ]

      for command <- commands do
        Memento.transaction!(fn ->
          user = insert(:user)

          assert :ok = Help.handle(user, ["HELP", command])

          assert_sent_message_contains(user.pid, ~r/Help for \x02#{command}\x02:/)
        end)
      end
    end

    test "handles HELP command for SET" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET"])

        assert_sent_messages_amount(user.pid, 31)
      end)
    end

    test "handles HELP command for SET boolean options" do
      # Group boolean SET options (ON/OFF options)
      boolean_options = [
        {"GUARD", 14},
        {"KEEPTOPIC", 14},
        {"PRIVATE", 14},
        {"RESTRICTED", 14},
        {"FANTASY", 16},
        {"OPNOTICE", 13},
        {"PEACE", 14},
        {"SECURE", 14},
        {"TOPICLOCK", 18}
      ]

      for {option, expected_messages} <- boolean_options do
        Memento.transaction!(fn ->
          user = insert(:user)

          assert :ok = Help.handle(user, ["HELP", "SET", option])

          assert_sent_messages_amount(user.pid, expected_messages)
        end)
      end
    end

    test "handles HELP command for SET value options" do
      # Group value SET options (options that take a value parameter)
      value_options = [
        {"DESC", 15},
        {"DESCRIPTION", 15},
        {"URL", 15},
        {"EMAIL", 15},
        {"ENTRYMSG", 15},
        {"SUCCESSOR", 17}
      ]

      for {option, expected_messages} <- value_options do
        Memento.transaction!(fn ->
          user = insert(:user)

          assert :ok = Help.handle(user, ["HELP", "SET", option])

          assert_sent_messages_amount(user.pid, expected_messages)
        end)
      end
    end

    test "handles HELP command for SET MLOCK" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "MLOCK"])
        assert_sent_message_contains(user.pid, ~r/Locks stable channel modes/)
      end)
    end

    test "handles HELP command with case insensitivity" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "set", "topiclock"])

        assert_sent_messages_amount(user.pid, 18)
      end)
    end

    test "handles HELP command for an unknown command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        unknown_command = "NONEXISTENT"

        assert :ok = Help.handle(user, ["HELP", unknown_command])

        assert_sent_messages_amount(user.pid, 2)
      end)
    end
  end
end
