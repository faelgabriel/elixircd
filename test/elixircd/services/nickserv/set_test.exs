defmodule ElixIRCd.Services.Nickserv.SetTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory
  import ExUnit.CaptureLog

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Jobs.VerificationEmailDelivery
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Services.Nickserv.Set
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "handles SET command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Set.handle(user, ["SET"])

        assert_sent_message_contains(user.pid, ~r/Insufficient parameters for.*SET/)
        assert_sent_message_contains(user.pid, ~r/NickServ.*NOTICE.*HIDEMAIL.*/)
        assert_sent_messages_amount(user.pid, 25)
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

        assert_sent_message_contains(user.pid, ~r/Unknown SET option:.*#{invalid_subcommand}/)
        assert_sent_message_contains(user.pid, ~r/NickServ.*NOTICE.*HIDEMAIL.*/)
        assert_sent_messages_amount(user.pid, 24)
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
        settings = %RegisteredNick.Settings{hide_email: false}
        registered_nick = insert(:registered_nick, settings: settings)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "ON"])

        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_nick.settings.hide_email == true

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your email address will now be hidden from \x02INFO\x02 displays.\r\n"}
        ])
      end)
    end

    test "handles SET HIDEMAIL OFF command successfully" do
      Memento.transaction!(fn ->
        settings = %RegisteredNick.Settings{hide_email: true}
        registered_nick = insert(:registered_nick, settings: settings)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "OFF"])

        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_nick.settings.hide_email == false

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your email address will now be shown in \x02INFO\x02 displays.\r\n"}
        ])
      end)
    end

    test "handles SET HIDEMAIL with case-insensitive values" do
      Memento.transaction!(fn ->
        settings = %RegisteredNick.Settings{hide_email: false}
        registered_nick = insert(:registered_nick, settings: settings)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "hidemail", "on"])

        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_nick.settings.hide_email == true

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your email address will now be hidden from \x02INFO\x02 displays.\r\n"}
        ])
      end)
    end

    test "preserves existing settings when updating HIDEMAIL" do
      Memento.transaction!(fn ->
        current_settings = RegisteredNick.Settings.new()

        current_settings_with_extras = Map.put(current_settings, :future_setting, "some_value")

        registered_nick = insert(:registered_nick, settings: current_settings_with_extras)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "ON"])

        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)

        assert updated_nick.settings.hide_email == true
        assert Map.get(updated_nick.settings, :future_setting) == "some_value"
      end)
    end

    test "handles error when updating settings fails" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "nonexistent_nick")

        log =
          capture_log(fn ->
            assert :ok = Set.handle(user, ["SET", "HIDEMAIL", "ON"])
          end)

        assert log =~ "Error updating settings for nonexistent_nick"
        assert log =~ ":registered_nick_not_found"

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :An error occurred while updating your NickServ settings.\r\n"}
        ])
      end)
    end

    test "implements the complete account preference set" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, nickname: "AccountNick", email: "old@example.com")

        insert(:registered_nick,
          nickname: "DisplayAlias",
          account_name: registered_nick.account_name,
          password_hash: registered_nick.password_hash,
          settings: registered_nick.settings
        )

        user = insert(:user, identified_as: registered_nick.account_name)

        for {option, value} <- [
              {"EMAILMEMOS", "ONLY"},
              {"ENFORCE", "ON"},
              {"ENFORCETIME", "30"},
              {"LANGUAGE", "pt-br"},
              {"KILL", "IMMED"},
              {"HIDESTATUS", "ON"},
              {"HIDEUSERMASK", "ON"},
              {"HIDEQUIT", "ON"},
              {"NEVERGROUP", "ON"},
              {"NEVEROP", "ON"},
              {"NOGREET", "ON"},
              {"PRIVATE", "ON"},
              {"QUIETCHG", "ON"},
              {"SECURE", "ON"},
              {"MSG", "ON"}
            ] do
          assert :ok = Set.handle(user, ["SET", option, value])
        end

        assert :ok = Set.handle(user, ["SET", "PROPERTY", "role", "admin"])
        assert :ok = Set.handle(user, ["SET", "URL", "https://example.com/profile"])
        assert :ok = Set.handle(user, ["SET", "DISPLAY", "DisplayAlias"])

        public_key = valid_compressed_public_key()
        assert :ok = Set.handle(user, ["SET", "PUBKEY", Base.encode64(public_key)])

        expect(JobQueue, :enqueue, fn VerificationEmailDelivery, payload, _opts ->
          assert payload["email"] == "new@example.com"
          :queued
        end)

        assert :ok = Set.handle(user, ["SET", "EMAIL", "new@example.com"])

        {:ok, updated} = RegisteredNicks.get_by_nickname(registered_nick.account_name)
        assert %Settings{} = updated.settings
        assert updated.settings.email_memos == :only
        assert updated.settings.enforce == true
        assert updated.settings.enforce_time == 30
        assert updated.settings.language == "pt-BR"
        assert updated.settings.kill == :immed
        assert updated.settings.hide_status == true
        assert updated.settings.hide_usermask == true
        assert updated.settings.hide_quit == true
        assert updated.settings.never_group == true
        assert updated.settings.never_op == true
        assert updated.settings.no_greet == true
        assert updated.settings.private == true
        assert updated.settings.quiet_chg == true
        assert updated.settings.secure == true
        assert updated.settings.msg == true
        assert updated.settings.property == %{"role" => "admin"}
        assert updated.settings.url == "https://example.com/profile"
        assert updated.settings.display == "DisplayAlias"
        assert Base.decode64!(updated.settings.pubkey) == public_key
        assert updated.email == "new@example.com"
        assert is_binary(updated.verify_code)
        assert is_nil(updated.verified_at)
      end)
    end

    test "validates URL, DISPLAY, PROPERTY, and PUBKEY inputs" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, nickname: "AccountNick")
        insert(:registered_nick, nickname: "OtherNick")
        user = insert(:user, identified_as: registered_nick.account_name)

        assert :ok = Set.handle(user, ["SET", "URL", "javascript:alert(1)"])
        assert :ok = Set.handle(user, ["SET", "DISPLAY", "OtherNick"])
        assert :ok = Set.handle(user, ["SET", "PROPERTY", "bad key", "value"])
        assert :ok = Set.handle(user, ["SET", "PUBKEY", "invalid"])
        assert :ok = Set.handle(user, ["SET", "PUBKEY", Base.encode64(<<2, 2, 0::248>>, padding: false)])
        assert_sent_message_contains(user.pid, ~r/Invalid public key/)

        {:ok, unchanged} = RegisteredNicks.get_by_nickname(registered_nick.account_name)
        assert is_nil(unchanged.settings.url)
        assert is_nil(unchanged.settings.display)
        assert unchanged.settings.property == %{}
        assert is_nil(unchanged.settings.pubkey)
      end)
    end

    test "covers validation, clearing, querying, and storage failure paths for every option" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, nickname: "AccountNick")
        user = insert(:user, identified_as: registered_nick.account_name)
        missing_user = insert(:user, identified_as: "missing_account")

        for params <- [
              ["SET", "ENFORCE", "OFF"],
              ["SET", "ENFORCE", "invalid"],
              ["SET", "ENFORCE"],
              ["SET", "EMAILMEMOS", "invalid"],
              ["SET", "EMAILMEMOS"],
              ["SET", "ENFORCETIME", "-1"],
              ["SET", "ENFORCETIME"],
              ["SET", "LANGUAGE", "en"],
              ["SET", "LANGUAGE", "xx"],
              ["SET", "LANGUAGE"],
              ["SET", "EMAIL", "invalid"],
              ["SET", "EMAIL"],
              ["SET", "URL", "OFF"],
              ["SET", "URL"],
              ["SET", "DISPLAY", "OFF"],
              ["SET", "DISPLAY", "bad nick"],
              ["SET", "DISPLAY"],
              ["SET", "PROPERTY", "LIST"],
              ["SET", "PROPERTY", "list"],
              ["SET", "PROPERTY", "role"],
              ["SET", "PROPERTY"],
              ["SET", "PROPERTY", "role", "value"],
              ["SET", "PROPERTY", "role", "OFF"],
              ["SET", "PUBKEY"],
              ["SET", "PUBKEY", "off"],
              ["SET", "PUBKEY", Base.encode64(<<2, 1, 0::248>>, padding: false)]
            ] do
          assert :ok = Set.handle(user, params)
        end

        public_key = valid_compressed_public_key()
        encoded_public_key = Base.encode64(public_key, padding: false)
        assert :ok = Set.handle(user, ["SET", "PUBKEY", encoded_public_key])
        assert :ok = Set.handle(user, ["SET", "PUBKEY"])
        assert :ok = Set.handle(user, ["SET", "PROPERTY", "role", "admin"])
        assert :ok = Set.handle(user, ["SET", "PROPERTY", "LIST"])

        assert :ok = Set.handle(user, ["SET", "PUBKEY", Base.encode64(<<2, 1, 0::248>>, padding: false)])

        missing_account_log =
          capture_log(fn ->
            for params <- [
                  ["SET", "ENFORCE", "ON"],
                  ["SET", "EMAILMEMOS", "ON"],
                  ["SET", "ENFORCETIME", "10"],
                  ["SET", "LANGUAGE", "pt-BR"],
                  ["SET", "EMAIL", "bad@example.com"],
                  ["SET", "URL", "OFF"],
                  ["SET", "DISPLAY", "OFF"],
                  ["SET", "PROPERTY", "role"],
                  ["SET", "PROPERTY", "missing", "value"],
                  ["SET", "PROPERTY", "LIST"],
                  ["SET", "PUBKEY"]
                ] do
              assert :ok = Set.handle(missing_user, params)
            end

            assert :ok = Set.handle(missing_user, ["SET", "DISPLAY", "ValidNick"])
          end)

        assert length(Regex.scan(~r/Error updating settings for missing_account/, missing_account_log)) == 12
        assert missing_account_log =~ ":registered_nick_not_found"

        assert :ok = Set.handle(user, ["SET", "EMAIL", "OFF"])
        assert :ok = Set.handle(user, ["SET", "EMAIL", "email@example.com"])
        assert :ok = Set.handle(user, ["SET", "EMAIL", "email@example.com"])

        services = Application.fetch_env!(:elixircd, :services)
        nickserv = Keyword.fetch!(services, :nickserv)
        required_nickserv = Keyword.put(nickserv, :email_required, true)
        Application.put_env(:elixircd, :services, Keyword.put(services, :nickserv, required_nickserv))

        try do
          assert :ok = Set.handle(user, ["SET", "EMAIL", "OFF"])
        after
          Application.put_env(:elixircd, :services, services)
        end
      end)
    end
  end

  defp valid_compressed_public_key do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    <<_prefix, x::binary-size(32), y::binary-size(32)>> = public_key
    prefix = if rem(:binary.last(y), 2) == 1, do: 3, else: 2
    <<prefix, x::binary>>
  end
end
