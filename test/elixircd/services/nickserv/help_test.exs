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

        assert_sent_messages_amount(user.pid, 18)
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

    test "handles HELP command for LOGOUT" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "LOGOUT"])

        assert_sent_messages_amount(user.pid, 11)
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

  describe "email_required notification" do
    test "displays email required message when email is required" do
      Memento.transaction!(fn ->
        original_config = Application.get_env(:elixircd, :services)
        email_required_config = put_in(original_config, [:nickserv, :email_required], true)
        Application.put_env(:elixircd, :services, email_required_config)
        on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "REGISTER"])

        assert_sent_message_contains(user.pid, ~r/This server REQUIRES an email address for registration/)
        assert_sent_message_contains(user.pid, ~r/You have to confirm the email address\. To do this, follow/)
        assert_sent_message_contains(user.pid, ~r/the instructions in the message sent to the email address/)
      end)
    end

    test "displays optional email message when email is not required" do
      Memento.transaction!(fn ->
        original_config = Application.get_env(:elixircd, :services)
        email_optional_config = put_in(original_config, [:nickserv, :email_required], false)
        Application.put_env(:elixircd, :services, email_optional_config)
        on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "REGISTER"])

        assert_sent_message_contains(user.pid, ~r/An email address is optional but recommended\. If provided,/)
        assert_sent_message_contains(user.pid, ~r/you can use it to reset your password if you forget it/)
      end)
    end
  end

  describe "pluralize_days pluralization" do
    test "uses 'day' for 1 day and 'days' for other values in FAQ help" do
      Memento.transaction!(fn ->
        original_config = Application.get_env(:elixircd, :services)
        one_day_config = put_in(original_config, [:nickserv, :unverified_expire_days], 1)
        Application.put_env(:elixircd, :services, one_day_config)
        on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "FAQ"])

        assert_sent_message_contains(user.pid, ~r/[Yy]ou must verify your nickname within 1 day/)
      end)

      Memento.transaction!(fn ->
        original_config = Application.get_env(:elixircd, :services)
        multiple_days_config = put_in(original_config, [:nickserv, :unverified_expire_days], 2)
        Application.put_env(:elixircd, :services, multiple_days_config)
        on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

        user = insert(:user)

        assert :ok = Help.handle(user, ["HELP", "FAQ"])

        assert_sent_message_contains(user.pid, ~r/[Yy]ou must verify your nickname within 2 days/)
      end)
    end
  end
end
