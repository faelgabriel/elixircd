defmodule ElixIRCd.Services.Nickserv.HelpTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv.Help

  describe "handle/2" do
    test "handles HELP command with no parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP"])

        assert_sent_messages_amount(user.pid, 17)
      end)
    end

    test "handles HELP command for REGISTER" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "REGISTER"])

        assert_sent_messages_amount(user.pid, 22)
      end)
    end

    test "handles HELP command for VERIFY" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "VERIFY"])

        assert_sent_messages_amount(user.pid, 10)
      end)
    end

    test "handles HELP command for IDENTIFY" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "IDENTIFY"])

        assert_sent_messages_amount(user.pid, 17)
      end)
    end

    test "handles HELP command for DROP" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "DROP"])

        assert_sent_messages_amount(user.pid, 19)
      end)
    end

    test "handles HELP command for GHOST" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "GHOST"])

        assert_sent_messages_amount(user.pid, 16)
      end)
    end

    test "handles HELP command for REGAIN" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "REGAIN"])

        assert_sent_messages_amount(user.pid, 14)
      end)
    end

    test "handles HELP command for RELEASE" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "RELEASE"])

        assert_sent_messages_amount(user.pid, 13)
      end)
    end

    test "handles HELP command for SET" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET"])

        assert_sent_messages_amount(user.pid, 15)
      end)
    end

    test "handles HELP command for SET HIDEMAIL as a single parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET HIDEMAIL"])

        assert_sent_messages_amount(user.pid, 16)
      end)
    end

    test "handles HELP command for SET HIDEMAIL as separate parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "HIDEMAIL"])

        assert_sent_messages_amount(user.pid, 16)
      end)
    end

    test "handles HELP command for set hidemail in lowercase" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "set", "hidemail"])

        assert_sent_messages_amount(user.pid, 16)
      end)
    end

    test "handles HELP command for INFO" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "INFO"])

        assert_sent_messages_amount(user.pid, 18)
      end)
    end

    test "handles HELP command for FAQ" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "FAQ"])

        assert_sent_messages_amount(user.pid, 31)
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
