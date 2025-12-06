defmodule ElixIRCd.Commands.SetnameTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Setname
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users

  describe "handle/2" do
    test "handles SETNAME command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "SETNAME", params: [], trailing: "New Name"}

        assert :ok = Setname.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles SETNAME command with no realname provided" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "SETNAME", params: []}

        assert :ok = Setname.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} SETNAME :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles SETNAME command when capability is not enabled" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:setname, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "SETNAME", params: [], trailing: "New Name"}

        assert :ok = Setname.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 421 #{user.nick} SETNAME :Unknown command\r\n"}
        ])
      end)
    end

    test "handles SETNAME command with empty realname" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:setname, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "SETNAME", params: [], trailing: ""}

        assert :ok = Setname.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test FAIL SETNAME INVALID_REALNAME :Realname cannot be empty\r\n"}
        ])
      end)
    end

    test "handles SETNAME command with realname too long" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:setname, true)
      )

      Memento.transaction!(fn ->
        max_realname_length = Application.get_env(:elixircd, :user)[:max_realname_length]
        user = insert(:user)
        too_long_realname = String.duplicate("a", max_realname_length + 1)
        message = %Message{command: "SETNAME", params: [], trailing: too_long_realname}

        assert :ok = Setname.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test FAIL SETNAME INVALID_REALNAME :Realname too long (maximum #{max_realname_length} characters)\r\n"}
        ])
      end)
    end

    test "handles SETNAME command with same realname" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:setname, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, realname: "Same Name")
        message = %Message{command: "SETNAME", params: [], trailing: "Same Name"}

        assert :ok = Setname.handle(user, message)

        # No message should be sent when realname doesn't change
        assert_sent_messages([])
      end)
    end

    test "handles SETNAME command successfully" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:setname, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, realname: "Old Name", capabilities: ["SETNAME"])
        watcher = insert(:user, capabilities: ["SETNAME"])

        # Users must share a channel to receive SETNAME
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        message = %Message{command: "SETNAME", params: [], trailing: "New Name"}

        assert :ok = Setname.handle(user, message)

        # Both the user and the watcher should receive the SETNAME notification
        assert_sent_messages([
          {user.pid, ":#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} SETNAME :New Name\r\n"},
          {watcher.pid, ":#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} SETNAME :New Name\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.realname == "New Name"
      end)
    end
  end
end
