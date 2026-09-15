defmodule ElixIRCd.Commands.ProtocolRegressionTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Command
  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Commands.Mode
  alias ElixIRCd.Commands.Nick
  alias ElixIRCd.Commands.Notice
  alias ElixIRCd.Commands.Privmsg
  alias ElixIRCd.Commands.Whois
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users

  test "PONG is silent and receives an ACK only when labeled" do
    Memento.transaction!(fn ->
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      assert :ok = Command.dispatch(user, Message.parse!("PONG :token"))
      assert_sent_messages([])
      assert :ok = Command.dispatch(user, Message.parse!("@label=pong PONG :token"))
      assert_sent_messages([{user.pid, "@label=pong :irc.test ACK\r\n"}])
    end)
  end

  test "a joining away user notifies only eligible observers" do
    Memento.transaction!(fn ->
      user = insert(:user, away_message: "Back later")
      watcher = insert(:user, capabilities: ["away-notify"])
      legacy = insert(:user)
      channel = insert(:channel)
      insert(:user_channel, user: watcher, channel: channel)
      insert(:user_channel, user: legacy, channel: channel)
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})
      assert_sent_messages_count_containing(watcher.pid, ~r/AWAY :Back later/, 1)
      assert_sent_messages_count_containing(legacy.pid, ~r/AWAY/, 0)
      assert_sent_messages_count_containing(user.pid, ~r/ 331 /, 0)
    end)
  end

  test "querying a channel with no modes returns a structured empty mode list" do
    Memento.transaction!(fn ->
      user = insert(:user)
      channel = insert(:channel, modes: [])
      insert(:user_channel, user: user, channel: channel)
      assert :ok = Mode.handle(user, %Message{command: "MODE", params: [channel.name]})

      assert_sent_messages([
        {user.pid, ":irc.test 324 #{user.nick} #{channel.name} +\r\n"},
        {user.pid, ":irc.test 329 #{user.nick} #{channel.name} #{DateTime.to_unix(channel.created_at)}\r\n"}
      ])
    end)
  end

  test "case-only NICK changes preserve identity and do not announce a disconnect" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "alice")
      watcher = insert(:user)
      insert(:user_monitor, user: watcher, target_nick: "alice")
      assert :ok = Nick.handle(user, %Message{command: "NICK", params: ["Alice"]})
      assert_sent_messages([{user.pid, ":#{user_mask(user)} NICK Alice\r\n"}])
      {:ok, updated} = Users.get_by_pid(user.pid)
      assert updated.nick == "Alice"
      assert updated.nick_key == "alice"
      assert :ok = Nick.handle(updated, %Message{command: "NICK", params: ["Alice"]})
      assert_sent_messages([])
    end)
  end

  test "empty NOTICE is silently discarded" do
    Memento.transaction!(fn ->
      user = insert(:user)
      target = insert(:user)
      assert :ok = Notice.handle(user, %Message{command: "NOTICE", params: [target.nick], trailing: ""})
      assert_sent_messages([])
    end)
  end

  for {module, command} <- [{Privmsg, "PRIVMSG"}, {Notice, "NOTICE"}] do
    test "#{command} preserves the +C exemption for channel operators" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target = insert(:user)
        channel = insert(:channel, modes: ["C"])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: target, channel: channel)

        assert :ok =
                 unquote(module).handle(user, %Message{
                   command: unquote(command),
                   params: [channel.name],
                   trailing: "\x01VERSION\x01"
                 })

        assert_sent_messages([
          {target.pid, ":#{user_mask(user)} #{unquote(command)} #{channel.name} :\x01VERSION\x01\r\n"}
        ])
      end)
    end
  end

  test "WHOIS resolves a server or local nick target and preserves channel status" do
    Memento.transaction!(fn ->
      user = insert(:user)
      target = insert(:user)

      for {name, modes} <- [{"#oper", ["o", "v"]}, {"#voice", ["v"]}] do
        channel = insert(:channel, name: name)
        insert(:user_channel, user: target, channel: channel, modes: modes)
      end

      for server <- ["IRC.TEST", target.nick] do
        assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: [server, target.nick]})
      end

      assert_sent_messages_count_containing(user.pid, ~r/ 311 /, 2)
      assert_sent_messages_count_containing(user.pid, ~r/ 319 .*@#oper/, 2)
      assert_sent_messages_count_containing(user.pid, ~r/ 319 .*\+#voice/, 2)
      assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: ["missing.server", target.nick]})
      assert_sent_messages_count_containing(user.pid, ~r/ 402 .*missing.server/, 1)
    end)
  end
end
