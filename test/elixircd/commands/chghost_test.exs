defmodule ElixIRCd.Commands.ChghostTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Chghost
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users

  describe "handle/2" do
    test "handles CHGHOST command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CHGHOST", params: ["target", "newident", "newhost"]}

        assert :ok = Chghost.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles CHGHOST command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "CHGHOST", params: ["target", "newident"]}

        assert :ok = Chghost.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} CHGHOST :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles CHGHOST command with non-operator user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CHGHOST", params: ["target", "newident", "newhost"]}

        assert :ok = Chghost.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission denied - You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles CHGHOST command with non-existent target" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "CHGHOST", params: ["nonexistent", "newident", "newhost"]}

        assert :ok = Chghost.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} nonexistent :No such nick/channel\r\n"}
        ])
      end)
    end

    test "handles CHGHOST command successfully" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        target = insert(:user, ident: "oldident", hostname: "oldhost.example.com")

        message = %Message{command: "CHGHOST", params: [target.nick, "newident", "newhost.example.com"]}

        assert :ok = Chghost.handle(operator, message)

        assert_sent_messages([
          {operator.pid,
           ":irc.test NOTICE #{operator.nick} :Changed host for #{target.nick} from oldident@oldhost.example.com to newident@newhost.example.com\r\n"}
        ])

        {:ok, updated_target} = Users.get_by_pid(target.pid)
        assert updated_target.ident == "newident"
        assert updated_target.hostname == "newhost.example.com"
      end)
    end

    test "notifies users with CHGHOST capability when host changes" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:chghost, true)
      )

      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        target = insert(:user, ident: "oldident", hostname: "oldhost.example.com")
        watcher = insert(:user, capabilities: ["CHGHOST"])

        # Users must share a channel to receive CHGHOST
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: target, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        message = %Message{command: "CHGHOST", params: [target.nick, "newident", "newhost.example.com"]}

        assert :ok = Chghost.handle(operator, message)

        assert_sent_messages([
          {operator.pid,
           ":irc.test NOTICE #{operator.nick} :Changed host for #{target.nick} from oldident@oldhost.example.com to newident@newhost.example.com\r\n"},
          {watcher.pid, ":#{target.nick}!oldident@oldhost.example.com CHGHOST newident newhost.example.com\r\n"}
        ])
      end)
    end

    test "handles CHGHOST with empty ident" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        target = insert(:user)

        message = %Message{command: "CHGHOST", params: [target.nick, "", "newhost.example.com"]}

        assert :ok = Chghost.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ":irc.test 468 #{operator.nick} :Invalid ident: cannot be empty\r\n"}
        ])
      end)
    end

    test "handles CHGHOST with ident too long" do
      Memento.transaction!(fn ->
        max_ident_length = Application.get_env(:elixircd, :user)[:max_ident_length]
        operator = insert(:user, modes: ["o"])
        target = insert(:user)
        long_ident = String.duplicate("a", max_ident_length + 1)

        message = %Message{command: "CHGHOST", params: [target.nick, long_ident, "newhost.example.com"]}

        assert :ok = Chghost.handle(operator, message)

        assert_sent_messages([
          {operator.pid,
           ":irc.test 468 #{operator.nick} :Invalid ident: too long (maximum #{max_ident_length} characters)\r\n"}
        ])
      end)
    end

    test "handles CHGHOST with invalid ident characters" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        target = insert(:user)

        message = %Message{command: "CHGHOST", params: [target.nick, "inv@lid", "newhost.example.com"]}

        assert :ok = Chghost.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ":irc.test 468 #{operator.nick} :Invalid ident: contains invalid characters\r\n"}
        ])
      end)
    end

    test "handles CHGHOST with empty hostname" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        target = insert(:user)

        message = %Message{command: "CHGHOST", params: [target.nick, "newident", ""]}

        assert :ok = Chghost.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ":irc.test NOTICE #{operator.nick} :Invalid hostname: cannot be empty\r\n"}
        ])
      end)
    end

    test "handles CHGHOST with hostname too long" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        target = insert(:user)
        long_hostname = String.duplicate("a", 254)

        message = %Message{command: "CHGHOST", params: [target.nick, "newident", long_hostname]}

        assert :ok = Chghost.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ":irc.test NOTICE #{operator.nick} :Invalid hostname: too long (maximum 253 characters)\r\n"}
        ])
      end)
    end

    test "handles CHGHOST with invalid hostname characters" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        target = insert(:user)

        message = %Message{command: "CHGHOST", params: [target.nick, "newident", "invalid host@name"]}

        assert :ok = Chghost.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ":irc.test NOTICE #{operator.nick} :Invalid hostname: contains invalid characters\r\n"}
        ])
      end)
    end
  end
end
