defmodule ElixIRCd.Commands.WhoisTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Whois
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WHOIS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WHOIS", params: ["#anything"]}

        assert :ok = Whois.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOIS", params: []}

        assert :ok = Whois.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} WHOIS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with inexistent user nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOIS", params: ["invalid.nick"]}

        assert :ok = Whois.handle(user, message)

        assert_no_user_whois_message(user, "invalid.nick")
      end)
    end

    test "handles WHOIS command with user nick target" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target, invisible target user and user does not share channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        _target_user = insert(:user, nick: "target_nick", modes: ["i"])

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_no_user_whois_message(user, "target_nick")
      end)
    end

    test "handles WHOIS command with user nick target, invisible target user and user shares channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: ["i"])
        channel = insert(:channel)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target, invisible target user and user does not share secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: ["i"])
        channel = insert(:channel, modes: ["s"])
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_no_user_whois_message(user, "target_nick")
      end)
    end

    test "handles WHOIS command with user nick target, invisible target user and user shares secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: ["i"])
        channel = insert(:channel, modes: ["s"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target and target user is an irc operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: ["o"])
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target and target user is away" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", away_message: "I'm away")
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target and target user is identified" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", identified_as: "account_name")
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end
  end

  @spec assert_user_whois_message(User.t(), User.t(), Channel.t()) :: :ok
  defp assert_user_whois_message(user, target_user, channel) do
    assert_sent_messages(
      [
        {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
        {user.pid, ":irc.test 319 #{user.nick} #{target_user.nick} :#{channel.name}\r\n"},
        {user.pid,
         ":irc.test 312 #{user.nick} #{target_user.nick} ElixIRCd #{Application.spec(:elixircd, :vsn)} :Elixir IRC daemon\r\n"},
        {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
        target_user.away_message &&
          {user.pid, ":irc.test 301 #{user.nick} #{target_user.nick} :#{target_user.away_message}\r\n"},
        target_user.modes |> Enum.find(fn mode -> mode == "o" end) &&
          {user.pid, ":irc.test 313 #{user.nick} #{target_user.nick} :is an IRC operator\r\n"},
        target_user.identified_as &&
          {user.pid,
           ":irc.test 330 #{user.nick} #{target_user.nick} #{target_user.identified_as} :is logged in as #{target_user.identified_as}\r\n"},
        {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
      ]
      |> Enum.reject(&(&1 == nil))
    )
  end

  @spec assert_no_user_whois_message(User.t(), String.t()) :: :ok
  defp assert_no_user_whois_message(user, target_nick) do
    assert_sent_messages([
      {user.pid, ":irc.test 401 #{user.nick} #{target_nick} :No such nick\r\n"},
      {user.pid, ":irc.test 318 #{user.nick} #{target_nick} :End of /WHOIS list.\r\n"}
    ])
  end
end
