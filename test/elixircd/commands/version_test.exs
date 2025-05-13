defmodule ElixIRCd.Commands.VersionTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Version
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles VERSION command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "VERSION", params: ["#anything"]}

        assert :ok = Version.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles VERSION command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "VERSION", params: []}
        elixircd_version = Application.spec(:elixircd, :vsn)

        assert :ok = Version.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 351 #{user.nick} ElixIRCd-#{elixircd_version} irc.test\r\n"},
          {user.pid,
           ~r/:irc\.test 005 #{user.nick} MODES=4 CHANLIMIT=#:20,&:5 PREFIX=\(ov\)@\+ NETWORK=ElixIRCdNet CHANTYPES=#& :are supported by this server\r\n/},
          {user.pid,
           ~r/:irc\.test 005 #{user.nick} TOPICLEN=300 KICKLEN=255 AWAYLEN=200 NICKLEN=30 CASEMAPPING=rfc1459 :are supported by this server\r\n/},
          {user.pid,
           ~r/:irc\.test 005 #{user.nick} CHANMODES=beI,k,l,imnpstqr MONITOR=100 SILENCE=20 TARGMAX=JOIN:4,NOTICE:4,PART:4,PRIVMSG:4 STATUSMSG=@\+ :are supported by this server\r\n/},
          {user.pid, ~r/:irc\.test 005 #{user.nick} EXCEPTS INVEX UHNAMES CALLERID :are supported by this server\r\n/}
        ])
      end)
    end
  end
end
