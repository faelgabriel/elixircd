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
      original_capabilities_config = Application.get_env(:elixircd, :capabilities)
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

      capabilities_config = [
        extended_names: true,
        extended_uhlist: true
      ]

      settings_config = [
        utf8_only: true,
        case_mapping: :rfc1459
      ]

      Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config, channel_config))
      Application.put_env(:elixircd, :user, Keyword.merge(original_user_config, user_config))
      Application.put_env(:elixircd, :capabilities, Keyword.merge(original_capabilities_config, capabilities_config))
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings_config, settings_config))

      user = insert(:user)
      assert :ok = Isupport.send_isupport_messages(user)

      assert_sent_messages([
        {user.pid,
         ":irc.test 005 #{user.nick} MODES=4 CHANLIMIT=#:20,&:5 PREFIX=(ov)@+ CHANTYPES=#& NICKLEN=30 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} NETWORK=Server Example CASEMAPPING=rfc1459 TOPICLEN=300 KICKLEN=255 AWAYLEN=200 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} CHANMODES=b,k,l,imnpst UHNAMES EXTENDED-UHLIST UMODES=BgHiorRwZ BOT=B :are supported by this server\r\n"},
        {user.pid, ":irc.test 005 #{user.nick} UTF8ONLY :are supported by this server\r\n"}
      ])

      Application.put_env(:elixircd, :channel, original_channel_config)
      Application.put_env(:elixircd, :user, original_user_config)
      Application.put_env(:elixircd, :capabilities, original_capabilities_config)
      Application.put_env(:elixircd, :settings, original_settings_config)
    end

    test "excludes boolean features when set to false" do
      original_capabilities_config = Application.get_env(:elixircd, :capabilities)
      original_settings_config = Application.get_env(:elixircd, :settings)

      capabilities_config = [
        extended_names: false,
        extended_uhlist: false
      ]

      settings_config = [
        utf8_only: false,
        case_mapping: :rfc1459
      ]

      Application.put_env(:elixircd, :capabilities, Keyword.merge(original_capabilities_config, capabilities_config))
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings_config, settings_config))

      user = insert(:user)
      assert :ok = Isupport.send_isupport_messages(user)

      # Should not contain UHNAMES, EXTENDED-UHLIST, or UTF8ONLY since they're set to false
      assert_sent_messages([
        {user.pid,
         ":irc.test 005 #{user.nick} MODES=20 CHANLIMIT=#:20,&:5 PREFIX=(ov)@+ CHANTYPES=#& NICKLEN=30 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} NETWORK=Server Example CASEMAPPING=rfc1459 TOPICLEN=300 KICKLEN=255 AWAYLEN=200 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} CHANMODES=b,k,l,imnpst UMODES=BgHiorRwZ BOT=B :are supported by this server\r\n"}
      ])

      Application.put_env(:elixircd, :capabilities, original_capabilities_config)
      Application.put_env(:elixircd, :settings, original_settings_config)
    end
  end
end
