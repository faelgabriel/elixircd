defmodule ElixIRCd.Commands.MotdTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Motd
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles MOTD command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "MOTD", params: ["#anything"]}

        assert :ok = Motd.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles MOTD command without config" do
      original_config = Application.get_env(:elixircd, :server)
      Application.put_env(:elixircd, :server, original_config |> Keyword.delete(:motd))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MOTD", params: []}

        assert :ok = Motd.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 375 #{user.nick} :irc.test Message of the Day\r\n"},
          {user.pid, ":irc.test 422 #{user.nick} :MOTD is missing\r\n"},
          {user.pid, ":irc.test 376 #{user.nick} :End of /MOTD command\r\n"}
        ])
      end)
    end

    test "handles MOTD command with string config" do
      original_config = Application.get_env(:elixircd, :server)
      Application.put_env(:elixircd, :server, original_config |> Keyword.put(:motd, "MOTD\r\Message\r\n"))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MOTD", params: []}

        assert :ok = Motd.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 375 #{user.nick} :irc.test Message of the Day\r\n"},
          {user.pid, ":irc.test 372 #{user.nick} :MOTD\r\n"},
          {user.pid, ":irc.test 372 #{user.nick} :Message\r\n"},
          {user.pid, ":irc.test 376 #{user.nick} :End of /MOTD command\r\n"}
        ])
      end)
    end

    test "handles MOTD command with File.read/1 success result config" do
      original_config = Application.get_env(:elixircd, :server)
      Application.put_env(:elixircd, :server, original_config |> Keyword.put(:motd, {:ok, "MOTD\r\Message\r\n"}))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MOTD", params: []}

        assert :ok = Motd.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 375 #{user.nick} :irc.test Message of the Day\r\n"},
          {user.pid, ":irc.test 372 #{user.nick} :MOTD\r\n"},
          {user.pid, ":irc.test 372 #{user.nick} :Message\r\n"},
          {user.pid, ":irc.test 376 #{user.nick} :End of /MOTD command\r\n"}
        ])
      end)
    end

    test "handles MOTD command with File.read/1 error result config" do
      original_config = Application.get_env(:elixircd, :server)
      Application.put_env(:elixircd, :server, original_config |> Keyword.put(:motd, {:error, :enoent}))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MOTD", params: []}

        assert :ok = Motd.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 375 #{user.nick} :irc.test Message of the Day\r\n"},
          {user.pid, ":irc.test 422 #{user.nick} :MOTD is missing\r\n"},
          {user.pid, ":irc.test 376 #{user.nick} :End of /MOTD command\r\n"}
        ])
      end)
    end
  end
end
