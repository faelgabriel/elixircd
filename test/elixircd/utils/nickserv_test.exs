defmodule ElixIRCd.Utils.NickservTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Utils.Nickserv

  describe "notify/2" do
    test "sends a single notice message to a user" do
      user = build(:user, nick: "test_user")
      message = "This is a test message"

      Dispatcher
      |> expect(:broadcast, fn msg, context, target_user ->
        assert context == :nickserv
        assert target_user == user
        assert msg.prefix == nil
        assert msg.command == "NOTICE"
        assert msg.params == ["test_user"]
        assert msg.trailing == message
        :ok
      end)

      assert Nickserv.notify(user, message) == :ok
    end

    test "sends multiple notice messages to a user" do
      user = build(:user, nick: "test_user")
      messages = ["Message 1", "Message 2", "Message 3"]

      Dispatcher
      |> expect(:broadcast, 3, fn msg, context, target_user ->
        assert context == :nickserv
        assert target_user == user
        assert msg.prefix == nil
        assert msg.command == "NOTICE"
        assert msg.params == ["test_user"]
        assert msg.trailing in messages
        :ok
      end)

      assert Nickserv.notify(user, messages) == :ok
    end

    test "uses PRIVMSG and the account language preference when configured" do
      user = build(:user, nick: "test_user", identified_as: "AccountNick")

      account =
        build(:registered_nick, nickname: "AccountNick", settings: Settings.new(%{msg: true, language: "pt-BR"}))

      RegisteredNicks
      |> expect(:get_by_nickname, fn "AccountNick" -> {:ok, account} end)

      Dispatcher
      |> expect(:broadcast, fn msg, context, target_user ->
        assert context == :nickserv
        assert target_user == user
        assert msg.command == "PRIVMSG"
        assert msg.params == ["test_user"]
        assert msg.trailing == "A configuração \x02HIDEMAIL\x02 agora está em \x02ON\x02."
        :ok
      end)

      assert Nickserv.notify(user, "Your \x02HIDEMAIL\x02 setting is now \x02ON\x02.") == :ok
    end
  end

  describe "email_required_format/1" do
    test "formats required email with angle brackets" do
      assert Nickserv.email_required_format(true) == "<email-address>"
    end

    test "formats optional email with square brackets" do
      assert Nickserv.email_required_format(false) == "[email-address]"
    end
  end

  describe "notify_literal/2" do
    test "sends each literal notice without translation" do
      user = build(:user, nick: "test_user")

      Dispatcher
      |> expect(:broadcast, 2, fn msg, :nickserv, ^user ->
        assert msg.trailing in ["literal one", "literal two"]
        :ok
      end)

      assert Nickserv.notify_literal(user, ["literal one", "literal two"]) == :ok
    end
  end

  describe "pending_email_active?/2" do
    test "returns false when a pending request is incomplete" do
      account =
        build(:registered_nick,
          pending_email: nil,
          pending_email_verify_code: nil,
          pending_email_requested_at: nil
        )

      refute Nickserv.pending_email_active?(account, DateTime.utc_now())
    end
  end

  describe "account settings helpers" do
    test "resolve settings, preserve false values, and apply defaults" do
      account = build(:registered_nick, nickname: "Account", settings: Settings.new(%{secure: false}))

      RegisteredNicks
      |> expect(:get_by_nickname, 6, fn
        "Account" -> {:ok, account}
        "Missing" -> {:error, :registered_nick_not_found}
      end)

      assert Nickserv.account_settings(build(:user, identified_as: "Account")) == account.settings
      assert Nickserv.account_settings(build(:user, identified_as: "Missing")) == nil
      assert Nickserv.account_settings(build(:user, identified_as: nil)) == nil

      assert Nickserv.account_setting?("Account", :secure) == false
      assert Nickserv.account_setting?("Missing", :secure) == false
      assert Nickserv.account_setting?(nil, :secure) == false
      assert Nickserv.account_setting("Account", :secure, true) == false
      assert Nickserv.account_setting("Missing", :secure, :fallback) == :fallback
      assert Nickserv.account_setting(nil, :secure, :fallback) == :fallback
    end

    test "handles transport security and configured display names" do
      account = build(:registered_nick, nickname: "Account", settings: Settings.new(%{display: "Alias"}))

      assert Nickserv.secure_connection?(build(:user, transport: :tls))
      assert Nickserv.secure_connection?(build(:user, transport: :wss))
      refute Nickserv.secure_connection?(build(:user, transport: :tcp))
      assert Nickserv.account_requires_secure_connection?(nil) == false
      assert Nickserv.account_display_name(account) == "Alias"
      assert Nickserv.account_display_name(%{account_name: "Account", settings: %{display: nil}}) == "Account"
    end
  end

  describe "get_account_nick/1" do
    test "resolves the canonical account record from a nickname" do
      grouped_nick = build(:registered_nick, %{nickname: "AliasNick", account_name: "AccountNick"})
      account_nick = build(:registered_nick, %{nickname: "AccountNick", account_name: "AccountNick"})

      RegisteredNicks
      |> expect(:get_by_nickname, 2, fn
        "AliasNick" -> {:ok, grouped_nick}
        "AccountNick" -> {:ok, account_nick}
      end)

      assert Nickserv.get_account_nick("AliasNick") == {:ok, account_nick}
    end

    test "resolves the canonical account record from a grouped nick" do
      registered_nick = build(:registered_nick, %{nickname: "AliasNick", account_name: "AccountNick"})
      account_nick = build(:registered_nick, %{nickname: "AccountNick", account_name: "AccountNick"})

      RegisteredNicks
      |> expect(:get_by_nickname, fn "AccountNick" ->
        {:ok, account_nick}
      end)

      assert Nickserv.get_account_nick(registered_nick) == {:ok, account_nick}
    end

    test "returns error when nickname cannot be resolved" do
      RegisteredNicks
      |> expect(:get_by_nickname, fn "MissingNick" ->
        {:error, :registered_nick_not_found}
      end)

      assert Nickserv.get_account_nick("MissingNick") == {:error, :registered_nick_not_found}
    end
  end

  describe "belongs_to_account?/2" do
    test "matches account names case-insensitively" do
      registered_nick = build(:registered_nick, %{nickname: "AliasNick", account_name: "AccountNick"})

      assert Nickserv.belongs_to_account?(registered_nick, "accountnick")
      refute Nickserv.belongs_to_account?(registered_nick, "OtherNick")
      refute Nickserv.belongs_to_account?(registered_nick, nil)
    end
  end

  describe "grouped?/1" do
    test "returns true only for non-primary grouped nicks" do
      grouped_nick = build(:registered_nick, %{nickname: "AliasNick", account_name: "AccountNick"})
      primary_nick = build(:registered_nick, %{nickname: "AccountNick", account_name: "AccountNick"})

      assert Nickserv.grouped?(grouped_nick)
      refute Nickserv.grouped?(primary_nick)
    end
  end

  describe "cleanup_channel_registrations/1" do
    test "clears successor references and deletes founded channels" do
      successor_channel = build(:registered_channel, %{name: "#succ", successor: "AccountNick"})
      founder_channel = build(:registered_channel, %{name: "#founder", founder: "AccountNick"})

      RegisteredChannels
      |> expect(:get_by_successor, fn "AccountNick" ->
        [successor_channel]
      end)

      RegisteredChannels
      |> expect(:update, fn ^successor_channel, %{successor: nil} ->
        successor_channel
      end)

      RegisteredChannels
      |> expect(:get_by_founder, fn "AccountNick" ->
        [founder_channel]
      end)

      RegisteredChannels
      |> expect(:delete, fn ^founder_channel ->
        :ok
      end)

      assert Nickserv.cleanup_channel_registrations("AccountNick") == :ok
    end
  end

  describe "notify_account_logout/1" do
    test "notifies self and account-notify watchers" do
      user = build(:user, nick: "test_user", capabilities: ["account-notify"])
      watcher = build(:user, nick: "watcher", capabilities: ["account-notify"])

      Users
      |> expect(:get_in_shared_channels_with_capability, fn ^user, "account-notify", true ->
        [user, watcher]
      end)

      Dispatcher
      |> expect(:broadcast, fn msg, context_user, recipients ->
        assert msg.command == "ACCOUNT"
        assert msg.params == ["*"]
        assert context_user == user
        assert recipients == [user, watcher]
        :ok
      end)

      assert Nickserv.notify_account_logout(user) == :ok
    end
  end
end
