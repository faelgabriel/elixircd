defmodule ElixIRCd.Services.Nickserv.SetTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Services.Nickserv.Set
  alias ElixIRCd.Tables.RegisteredNick

  describe "handle/2" do
    test "handles SET command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Set.handle(user, ["SET"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02SET\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02SET <option> <parameters>\x02\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Available SET options:\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*HIDEMAIL.*/}
        ])
      end)
    end

    test "handles SET command when user is not identified" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "ON"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must identify to NickServ before using the SET command.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Use \x02/msg NickServ IDENTIFY <password>\x02 to identify.\r\n"}
        ])
      end)
    end

    test "handles SET command with invalid subcommand" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        invalid_subcommand = "INVALID"

        assert :ok = Set.handle(user, ["SET", invalid_subcommand])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Unknown SET option: \x02#{invalid_subcommand}\x02\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Available SET options:\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*HIDEMAIL.*/}
        ])
      end)
    end

    test "handles SET HIDEMAIL command with insufficient parameters" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02HIDEMAIL\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02SET HIDEMAIL {ON|OFF}\x02\r\n"}
        ])
      end)
    end

    test "handles SET HIDEMAIL command with invalid parameter" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "INVALID"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Invalid parameter for \x02HIDEMAIL\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02SET HIDEMAIL {ON|OFF}\x02\r\n"}
        ])
      end)
    end

    test "handles SET HIDEMAIL ON command successfully" do
      Memento.transaction!(fn ->
        # Create settings with hide_email: false
        settings = %RegisteredNick.Settings{hide_email: false}
        registered_nick = insert(:registered_nick, settings: settings)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "ON"])

        # Verify the setting was updated
        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_nick.settings.hide_email == true

        # Verify the message sent to the user
        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your email address will now be hidden from \x02INFO\x02 displays.\r\n"}
        ])
      end)
    end

    test "handles SET HIDEMAIL OFF command successfully" do
      Memento.transaction!(fn ->
        # Create settings with hide_email: true
        settings = %RegisteredNick.Settings{hide_email: true}
        registered_nick = insert(:registered_nick, settings: settings)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "OFF"])

        # Verify the setting was updated
        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_nick.settings.hide_email == false

        # Verify the message sent to the user
        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your email address will now be shown in \x02INFO\x02 displays.\r\n"}
        ])
      end)
    end

    test "handles SET HIDEMAIL with case-insensitive values" do
      Memento.transaction!(fn ->
        # Create settings with hide_email: false
        settings = %RegisteredNick.Settings{hide_email: false}
        registered_nick = insert(:registered_nick, settings: settings)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "hidemail", "on"])

        # Verify the setting was updated
        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_nick.settings.hide_email == true

        # Verify the message sent to the user
        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your email address will now be hidden from \x02INFO\x02 displays.\r\n"}
        ])
      end)
    end

    test "preserves existing settings when updating HIDEMAIL" do
      Memento.transaction!(fn ->
        # Create a settings struct with additional fields if added in the future
        current_settings = RegisteredNick.Settings.new()

        # Mock additional field in the settings (simulating future additions)
        current_settings_with_extras = Map.put(current_settings, :future_setting, "some_value")

        registered_nick = insert(:registered_nick, settings: current_settings_with_extras)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "ON"])

        # Verify the setting was updated
        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)

        # Check that the hidemail setting was updated
        assert updated_nick.settings.hide_email == true

        # Check that the future_setting was preserved
        assert Map.get(updated_nick.settings, :future_setting) == "some_value"
      end)
    end
  end
end
