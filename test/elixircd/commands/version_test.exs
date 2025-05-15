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
      original_channel_config = Application.get_env(:elixircd, :channel)
      original_user_config = Application.get_env(:elixircd, :user)
      original_features_config = Application.get_env(:elixircd, :features)

      channel_config = [
        modes: 4,
        chanlimit: %{"#" => 20, "&" => 5},
        prefix: %{modes: "ov", prefixes: "@+"},
        chantypes: "#&",
        topiclen: 300,
        kicklen: 255,
        targmax: %{"JOIN" => 4, "NOTICE" => 4, "PART" => 4, "PRIVMSG" => 4},
        statusmsg: "@+",
        excepts: false,
        invex: true
      ]

      user_config = [
        awaylen: 200,
        nicklen: 30
      ]

      features_config = [
        casemapping: "rfc1459",
        uhnames: true,
        callerid: true,
        monitor: 100,
        silence: 20
      ]

      :ok = Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config, channel_config))
      :ok = Application.put_env(:elixircd, :user, Keyword.merge(original_user_config, user_config))
      :ok = Application.put_env(:elixircd, :features, Keyword.merge(original_features_config, features_config))

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "VERSION", params: []}
        elixircd_version = Application.spec(:elixircd, :vsn)

        assert :ok = Version.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 351 #{user.nick} ElixIRCd-#{elixircd_version} irc.test\r\n"},
          {user.pid,
           ":irc.test 005 #{user.nick} MODES=4 CHANLIMIT=#:20,&:5 PREFIX=(ov)@+ CHANTYPES=#& NICKLEN=30 :are supported by this server\r\n"},
          {user.pid,
           ":irc.test 005 #{user.nick} NETWORK=Server Example CASEMAPPING=rfc1459 TOPICLEN=300 KICKLEN=255 AWAYLEN=200 :are supported by this server\r\n"},
          {user.pid,
           ":irc.test 005 #{user.nick} MONITOR=100 SILENCE=20 CHANMODES=b,k,l,imnpst TARGMAX=JOIN:4,NOTICE:4,PART:4,PRIVMSG:4 STATUSMSG=@+ :are supported by this server\r\n"},
          {user.pid, ":irc.test 005 #{user.nick} INVEX UHNAMES CALLERID :are supported by this server\r\n"}
        ])
      end)

      :ok = Application.put_env(:elixircd, :channel, original_channel_config)
      :ok = Application.put_env(:elixircd, :user, original_user_config)
      :ok = Application.put_env(:elixircd, :features, original_features_config)
    end
  end
end
