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

        assert_sent_messages_amount(user.pid, 15)
      end)
    end

    test "handles HELP command for REGISTER" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "REGISTER"])

        assert_sent_messages_amount(user.pid, 18)
      end)
    end

    test "handles HELP command for DROP" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "DROP"])

        assert_sent_messages_amount(user.pid, 20)
      end)
    end

    test "handles HELP command for SET" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET"])

        assert_sent_messages_amount(user.pid, 29)
      end)
    end

    test "handles HELP command for SET GUARD" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "GUARD"])

        assert_sent_messages_amount(user.pid, 14)
      end)
    end

    test "handles HELP command for SET KEEPTOPIC" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "KEEPTOPIC"])

        assert_sent_messages_amount(user.pid, 14)
      end)
    end

    test "handles HELP command for SET PRIVATE" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "PRIVATE"])

        assert_sent_messages_amount(user.pid, 14)
      end)
    end

    test "handles HELP command for SET RESTRICTED" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "RESTRICTED"])

        assert_sent_messages_amount(user.pid, 14)
      end)
    end

    test "handles HELP command for SET FANTASY" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "FANTASY"])

        assert_sent_messages_amount(user.pid, 16)
      end)
    end

    test "handles HELP command for SET DESCRIPTION" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "DESCRIPTION"])

        assert_sent_messages_amount(user.pid, 15)
      end)
    end

    test "handles HELP command for SET URL" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "URL"])

        assert_sent_messages_amount(user.pid, 15)
      end)
    end

    test "handles HELP command for SET EMAIL" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "EMAIL"])

        assert_sent_messages_amount(user.pid, 15)
      end)
    end

    test "handles HELP command for SET ENTRYMSG" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "ENTRYMSG"])

        assert_sent_messages_amount(user.pid, 15)
      end)
    end

    test "handles HELP command for SET OPNOTICE" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "OPNOTICE"])

        assert_sent_messages_amount(user.pid, 13)
      end)
    end

    test "handles HELP command for SET PEACE" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "PEACE"])

        assert_sent_messages_amount(user.pid, 14)
      end)
    end

    test "handles HELP command for SET SECURE" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "SECURE"])

        assert_sent_messages_amount(user.pid, 14)
      end)
    end

    test "handles HELP command for SET TOPICLOCK" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "TOPICLOCK"])

        assert_sent_messages_amount(user.pid, 17)
      end)
    end

    test "handles HELP command for SET DESC (alias for DESCRIPTION)" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET", "DESC"])

        assert_sent_messages_amount(user.pid, 15)
      end)
    end

    test "handles HELP command for set topiclock in lowercase" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "set", "topiclock"])

        assert_sent_messages_amount(user.pid, 17)
      end)
    end

    test "handles HELP command for SET TOPICLOCK as a single parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "SET TOPICLOCK"])

        assert_sent_messages_amount(user.pid, 17)
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
