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
      original_features_config = Application.get_env(:elixircd, :features)
      original_settings_config = Application.get_env(:elixircd, :settings)

      channel_config = [
        max_modes_per_command: 4,
        channel_join_limits: %{"#" => 20, "&" => 5},
        status_prefixes: %{modes: "ov", prefixes: "@+"},
        channel_prefixes: ["#", "&"],
        max_topic_length: 300,
        max_kick_message_length: 255,
        max_command_targets: %{"JOIN" => 4, "NOTICE" => 4, "PART" => 4, "PRIVMSG" => 4},
        status_message_targets: "@+",
        support_ban_exceptions: false,
        support_invite_exceptions: true
      ]

      user_config = [
        max_away_message_length: 200,
        max_nick_length: 30
      ]

      features_config = [
        case_mapping: :rfc1459,
        support_extended_names: true,
        support_callerid_mode: true,
        max_monitored_nicks: 100,
        max_silence_entries: 20
      ]

      settings_config = [
        utf8_only: true
      ]

      :ok = Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config, channel_config))
      :ok = Application.put_env(:elixircd, :user, Keyword.merge(original_user_config, user_config))
      :ok = Application.put_env(:elixircd, :features, Keyword.merge(original_features_config, features_config))
      :ok = Application.put_env(:elixircd, :settings, Keyword.merge(original_settings_config, settings_config))

      user = insert(:user)
      assert :ok = Isupport.send_isupport_messages(user)

      assert_sent_messages([
        {user.pid,
         ":irc.test 005 #{user.nick} MODES=4 CHANLIMIT=#:20,&:5 PREFIX=(ov)@+ CHANTYPES=#& NICKLEN=30 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} NETWORK=Server Example CASEMAPPING=rfc1459 TOPICLEN=300 KICKLEN=255 AWAYLEN=200 :are supported by this server\r\n"},
        {user.pid,
         ":irc.test 005 #{user.nick} MONITOR=100 SILENCE=20 CHANMODES=b,k,l,imnpst TARGMAX=JOIN:4,NOTICE:4,PART:4,PRIVMSG:4 STATUSMSG=@+ :are supported by this server\r\n"},
        {user.pid, ":irc.test 005 #{user.nick} INVEX UHNAMES CALLERID UTF8ONLY :are supported by this server\r\n"}
      ])

      :ok = Application.put_env(:elixircd, :channel, original_channel_config)
      :ok = Application.put_env(:elixircd, :user, original_user_config)
      :ok = Application.put_env(:elixircd, :features, original_features_config)
      :ok = Application.put_env(:elixircd, :settings, original_settings_config)
    end
  end
end
