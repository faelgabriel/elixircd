defmodule ElixIRCd.Utils.IsupportTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Utils.Isupport

  describe "send_isupport_messages/1" do
    test "sends ISUPPORT messages to the user" do
      original_channel_config = Application.get_env(:elixircd, :channel)
      original_user_config = Application.get_env(:elixircd, :user)
      original_whox_config = Application.get_env(:elixircd, :whox)
      original_settings_config = Application.get_env(:elixircd, :settings)

      channel_config = [
        max_modes_per_command: 4,
        channel_join_limits: %{"#" => 20, "&" => 5},
        channel_prefixes: ["#", "&"],
        max_topic_length: 300,
        max_kick_message_length: 255
      ]

      user_config = [
        max_away_message_length: 200,
        max_nick_length: 30
      ]

      whox_config = [
        enabled: true
      ]

      settings_config = [
        utf8_only: true,
        case_mapping: :rfc1459
      ]

      Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config, channel_config))
      Application.put_env(:elixircd, :user, Keyword.merge(original_user_config, user_config))
      Application.put_env(:elixircd, :whox, Keyword.merge(original_whox_config, whox_config))
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings_config, settings_config))

      on_exit(fn ->
        Application.put_env(:elixircd, :channel, original_channel_config)
        Application.put_env(:elixircd, :user, original_user_config)
        Application.put_env(:elixircd, :whox, original_whox_config)
        Application.put_env(:elixircd, :settings, original_settings_config)
      end)

      user = insert(:user)
      assert :ok = Isupport.send_isupport_messages(user)

      assert_sent_messages([
        {user.pid,
         ":irc.test 005 #{user.nick} MODES=4 CHANLIMIT=#:20,&:5 PREFIX=(ov)@+ CHANTYPES=#& NICKLEN=30 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} NETWORK=Server Example CASEMAPPING=rfc1459 TOPICLEN=300 KICKLEN=255 AWAYLEN=200 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} CHANMODES=beI,k,djl,CcimMNnOprRstTUuz WHOX UMODES=BgHiorRsTwxZ BOT=B UTF8ONLY :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} MONITOR=100 TARGMAX=NAMES:20,LIST:1,KICK:4,WHOIS:1,PRIVMSG:4,NOTICE:4,TAGMSG:4,MONITOR:100 EXCEPTS=e INVEX=I ELIST=MNUCT :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} SAFELIST STATUSMSG=@+ CHANNELLEN=64 USERLEN=10 MAXLIST=I:100,b:100,e:100 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} SILENCE=15 EXTBAN=$,amr ACCOUNTEXTBAN=a CHATHISTORY=100 MSGREFTYPES=msgid,timestamp :are supported by this server\r\n"}
      ])
    end

    test "excludes boolean features when set to false" do
      original_channel_config = Application.get_env(:elixircd, :channel)
      original_whox_config = Application.get_env(:elixircd, :whox)
      original_settings_config = Application.get_env(:elixircd, :settings)

      channel_config = [
        max_modes_per_command: 20
      ]

      whox_config = [
        enabled: false
      ]

      settings_config = [
        utf8_only: false,
        case_mapping: :rfc1459
      ]

      Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config, channel_config))
      Application.put_env(:elixircd, :whox, Keyword.merge(original_whox_config, whox_config))
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings_config, settings_config))

      on_exit(fn ->
        Application.put_env(:elixircd, :channel, original_channel_config)
        Application.put_env(:elixircd, :whox, original_whox_config)
        Application.put_env(:elixircd, :settings, original_settings_config)
      end)

      user = insert(:user)
      assert :ok = Isupport.send_isupport_messages(user)

      # Should not contain WHOX or UTF8ONLY since they're set to false
      assert_sent_messages([
        {user.pid,
         ":irc.test 005 #{user.nick} MODES=20 CHANLIMIT=#:20,&:5 PREFIX=(ov)@+ CHANTYPES=#& NICKLEN=30 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} NETWORK=Server Example CASEMAPPING=rfc1459 TOPICLEN=300 KICKLEN=255 AWAYLEN=200 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} CHANMODES=beI,k,djl,CcimMNnOprRstTUuz UMODES=BgHiorRsTwxZ BOT=B MONITOR=100 TARGMAX=NAMES:20,LIST:1,KICK:4,WHOIS:1,PRIVMSG:4,NOTICE:4,TAGMSG:4,MONITOR:100 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} EXCEPTS=e INVEX=I ELIST=MNUCT SAFELIST STATUSMSG=@+ :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} CHANNELLEN=64 USERLEN=10 MAXLIST=I:100,b:100,e:100 SILENCE=15 EXTBAN=$,amr :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} ACCOUNTEXTBAN=a CHATHISTORY=100 MSGREFTYPES=msgid,timestamp :are supported by this server\r\n"}
      ])
    end

    test "advertises the canonical strict-rfc1459 case mapping token" do
      original_settings = Application.fetch_env!(:elixircd, :settings)

      Application.put_env(
        :elixircd,
        :settings,
        Keyword.put(original_settings, :case_mapping, :strict_rfc1459)
      )

      on_exit(fn -> Application.put_env(:elixircd, :settings, original_settings) end)

      assert Enum.member?(Isupport.feature_tokens(), "CASEMAPPING=strict-rfc1459")
    end

    test "advertises deprecated metadata only when compatibility is enabled" do
      original = Application.fetch_env!(:elixircd, :compatibility)
      on_exit(fn -> Application.put_env(:elixircd, :compatibility, original) end)
      Application.put_env(:elixircd, :compatibility, Keyword.put(original, :deprecated_metadata, true))
      assert "METADATA=20" in Isupport.feature_tokens()
    end
  end
end
