defmodule ElixIRCd.Utils.Isupport do
  @moduledoc """
  Module for handling IRC ISUPPORT message generation.
  """

  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  # Maximum number of feature tokens per ISUPPORT message
  @max_features_per_batch 5

  @doc """
  Sends ISUPPORT messages to the user.
  """
  @spec send_isupport_messages(User.t()) :: :ok
  def send_isupport_messages(user) do
    all_features = get_all_feature_tokens()

    all_features
    |> Enum.chunk_every(@max_features_per_batch)
    |> Enum.each(fn feature_batch ->
      Message.build(%{
        prefix: :server,
        command: :rpl_isupport,
        params: [user.nick | feature_batch],
        trailing: "are supported by this server"
      })
      |> Dispatcher.broadcast(user)
    end)
  end

  @spec get_all_feature_tokens() :: [String.t()]
  defp get_all_feature_tokens do
    user_config = Application.get_env(:elixircd, :user)
    channel_config = Application.get_env(:elixircd, :channel)
    server_config = Application.get_env(:elixircd, :server)
    features_config = Application.get_env(:elixircd, :features)

    [
      format_feature(:numeric, "MODES", channel_config[:max_modes_per_command]),
      format_feature(:map, "CHANLIMIT", channel_config[:channel_join_limits]),
      format_feature(:prefix, "PREFIX", channel_config[:status_prefixes]),
      format_feature(:list, "CHANTYPES", channel_config[:channel_prefixes]),
      format_feature(:numeric, "NICKLEN", user_config[:max_nick_length]),
      format_feature(:string, "NETWORK", server_config[:name]),
      format_feature(:string, "CASEMAPPING", features_config[:case_mapping]),
      format_feature(:numeric, "TOPICLEN", channel_config[:max_topic_length]),
      format_feature(:numeric, "KICKLEN", channel_config[:max_kick_message_length]),
      format_feature(:numeric, "AWAYLEN", user_config[:max_away_message_length]),
      format_feature(:numeric, "MONITOR", features_config[:max_monitored_nicks]),
      format_feature(:numeric, "SILENCE", features_config[:max_silence_entries]),
      format_feature(:string, "CHANMODES", format_chanmodes()),
      format_feature(:map, "TARGMAX", channel_config[:max_command_targets]),
      format_feature(:string, "STATUSMSG", channel_config[:status_message_targets]),
      format_feature(:boolean, "EXCEPTS", channel_config[:support_ban_exceptions]),
      format_feature(:boolean, "INVEX", channel_config[:support_invite_exceptions]),
      format_feature(:boolean, "UHNAMES", features_config[:support_extended_names]),
      format_feature(:boolean, "CALLERID", features_config[:support_callerid_mode])
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec format_chanmodes() :: String.t()
  defp format_chanmodes do
    user_channel_modes = ["o", "v"]

    supported_modes =
      ChannelModes.modes()
      |> Enum.filter(&(&1 not in user_channel_modes))

    # Categorize according to IRC spec:
    # Type A = List modes (always require a parameter for both set/unset)
    type_a = ["b"] |> Enum.filter(&(&1 in supported_modes))

    # Type B = Modes that require parameter only when setting
    type_b = ["k"] |> Enum.filter(&(&1 in supported_modes))

    # Type C = Modes requiring parameter in specific cases
    type_c = ["l"] |> Enum.filter(&(&1 in supported_modes))

    # Type D = Modes that never take a parameter
    # These are all remaining modes that aren't user-modes (o,v) and aren't in previous categories
    type_d = supported_modes -- (type_a ++ type_b ++ type_c)

    # Format the output as A,B,C,D
    # IRC spec requires the categories be separated by commas, with modes concatenated within each category
    type_a_str = Enum.join(type_a, "")
    type_b_str = Enum.join(type_b, "")
    type_c_str = Enum.join(type_c, "")
    type_d_str = Enum.join(type_d, "")

    "#{type_a_str},#{type_b_str},#{type_c_str},#{type_d_str}"
  end

  @spec format_feature(atom(), String.t(), any()) :: String.t() | nil
  defp format_feature(:map, name, map) do
    sep = ":"
    join_char = ","
    formatted_map = Enum.map_join(map, join_char, fn {key, val} -> "#{key}#{sep}#{val}" end)
    "#{name}=#{formatted_map}"
  end

  defp format_feature(:numeric, name, value), do: "#{name}=#{value}"
  defp format_feature(:string, name, value), do: "#{name}=#{value}"
  defp format_feature(:list, name, list) when is_list(list), do: "#{name}=#{Enum.join(list, "")}"
  defp format_feature(:prefix, name, %{modes: modes, prefixes: prefixes}), do: "#{name}=(#{modes})#{prefixes}"
  defp format_feature(:boolean, _name, false), do: nil
  defp format_feature(:boolean, name, true), do: name
end
