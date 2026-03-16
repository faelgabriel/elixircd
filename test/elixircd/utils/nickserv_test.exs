defmodule ElixIRCd.Utils.NickservTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
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
  end

  describe "email_required_format/1" do
    test "formats required email with angle brackets" do
      assert Nickserv.email_required_format(true) == "<email-address>"
    end

    test "formats optional email with square brackets" do
      assert Nickserv.email_required_format(false) == "[email-address]"
    end
  end

  describe "get_account_nick/1" do
    test "resolves the canonical account record from a grouped nick" do
      registered_nick = build(:registered_nick, %{nickname: "AliasNick", account_name: "AccountNick"})
      account_nick = build(:registered_nick, %{nickname: "AccountNick", account_name: "AccountNick"})

      RegisteredNicks
      |> expect(:get_by_nickname, fn "AccountNick" ->
        {:ok, account_nick}
      end)

      assert Nickserv.get_account_nick(registered_nick) == {:ok, account_nick}
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
      user = build(:user, nick: "test_user")
      watcher = build(:user, nick: "watcher", capabilities: ["ACCOUNT-NOTIFY"])

      Application
      |> expect(:get_env, fn :elixircd, :capabilities ->
        %{account_notify: true}
      end)

      Users
      |> expect(:get_in_shared_channels_with_capability, fn ^user, "ACCOUNT-NOTIFY", true ->
        [user, watcher]
      end)

      Dispatcher
      |> expect(:broadcast, fn msg, context_user, recipients ->
        assert msg.command == "ACCOUNT"
        assert msg.params == ["*"]
        assert context_user == user
        assert recipients == [user]
        :ok
      end)

      Dispatcher
      |> expect(:broadcast, fn msg, context_user, recipients ->
        assert msg.command == "ACCOUNT"
        assert msg.params == ["*"]
        assert context_user == user
        assert recipients == [watcher]
        :ok
      end)

      assert Nickserv.notify_account_logout(user) == :ok
    end
  end
end
