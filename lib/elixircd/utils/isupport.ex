defmodule ElixIRCd.Utils.Isupport do
  @moduledoc """
  Module for handling IRC ISUPPORT message generation.
  """

  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.Commands.Mode.UserModes
  alias ElixIRCd.Message
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Monitor
  alias ElixIRCd.Utils.Targets

  # Maximum number of feature tokens per ISUPPORT message
  @max_features_per_batch 5

  @doc """
  Sends ISUPPORT messages to the user.
  """
  @spec send_isupport_messages(User.t()) :: :ok
  def send_isupport_messages(user) do
    send_feature_tokens(user, feature_tokens())
  end

  @spec send_feature_tokens(User.t(), [String.t()]) :: :ok
  defp send_feature_tokens(user, tokens) do
    tokens
    |> Enum.chunk_every(@max_features_per_batch)
    |> Enum.each(fn feature_batch ->
      %Message{command: :rpl_isupport, params: [user.nick | feature_batch], trailing: "are supported by this server"}
      |> Dispatcher.broadcast(:server, user)
    end)
  end

  @doc """
  Returns the current ISUPPORT tokens advertised by the server.
  """
  @spec feature_tokens() :: [String.t()]
  def feature_tokens do
    user_config = Application.fetch_env!(:elixircd, :user)
    channel_config = Application.fetch_env!(:elixircd, :channel)
    server_config = Application.fetch_env!(:elixircd, :server)
    whox_config = Application.fetch_env!(:elixircd, :whox)
    settings_config = Application.fetch_env!(:elixircd, :settings)

    [
      format_feature(:numeric, "MODES", channel_config[:max_modes_per_command]),
      format_feature(:map, "CHANLIMIT", channel_config[:channel_join_limits]),
      format_feature(:string, "PREFIX", format_prefix()),
      format_deprecated_metadata(),
      format_feature(:list, "CHANTYPES", channel_config[:channel_prefixes]),
      format_feature(:numeric, "NICKLEN", user_config[:max_nick_length]),
      format_feature(:string, "NETWORK", server_config[:name]),
      format_feature(:string, "CASEMAPPING", format_case_mapping(settings_config[:case_mapping])),
      format_feature(:numeric, "TOPICLEN", channel_config[:max_topic_length]),
      format_feature(:numeric, "KICKLEN", channel_config[:max_kick_message_length]),
      format_feature(:numeric, "AWAYLEN", user_config[:max_away_message_length]),
      format_feature(:string, "CHANMODES", format_chanmodes()),
      format_feature(:boolean, "WHOX", Keyword.fetch!(whox_config, :enabled)),
      format_feature(:string, "UMODES", format_umodes()),
      format_feature(:string, "BOT", "B"),
      format_feature(:boolean, "UTF8ONLY", settings_config[:utf8_only]),
      format_monitor_feature(),
      format_feature(:string, "TARGMAX", Targets.targmax_value(monitor_max_targets())),
      format_feature(:string, "EXCEPTS", "e"),
      format_feature(:string, "INVEX", "I"),
      format_feature(:string, "ELIST", "MNUCT"),
      format_feature(:boolean, "SAFELIST", true),
      format_feature(:string, "STATUSMSG", "@+"),
      format_feature(:numeric, "CHANNELLEN", channel_config[:max_channel_name_length]),
      format_feature(:numeric, "USERLEN", user_config[:max_ident_length]),
      format_feature(:string, "MAXLIST", format_maxlist(channel_config[:max_list_entries])),
      format_feature(:numeric, "SILENCE", 15),
      format_feature(:string, "EXTBAN", "$,amr"),
      format_feature(:string, "ACCOUNTEXTBAN", "a"),
      format_history_limit(),
      format_feature(:string, "MSGREFTYPES", "msgid,timestamp")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp format_history_limit do
    history = Application.fetch_env!(:elixircd, :history)
    if history[:enabled], do: "CHATHISTORY=#{history[:max_request_limit]}"
  end

  defp format_deprecated_metadata do
    if Application.fetch_env!(:elixircd, :compatibility)[:deprecated_metadata] do
      "METADATA=#{Application.fetch_env!(:elixircd, :metadata)[:max_keys]}"
    end
  end

  @doc """
  Announces added, changed and removed ISUPPORT tokens to registered clients.
  Removed tokens use the ISUPPORT minus prefix.
  """
  @spec notify_changes([String.t()]) :: :ok
  def notify_changes(previous_tokens) do
    current_tokens = feature_tokens()
    current_names = MapSet.new(current_tokens, &token_name/1)

    removed_tokens =
      previous_tokens
      |> Enum.reject(&MapSet.member?(current_names, token_name(&1)))
      |> Enum.map(&("-" <> token_name(&1)))

    changed_tokens = (current_tokens -- previous_tokens) ++ removed_tokens

    if changed_tokens != [] do
      Users.get_all()
      |> Enum.filter(& &1.registered)
      |> Enum.each(&send_feature_tokens(&1, changed_tokens))
    end

    :ok
  end

  @spec token_name(String.t()) :: String.t()
  defp token_name(token), do: token |> String.split("=", parts: 2) |> hd()

  @spec format_umodes() :: String.t()
  defp format_umodes do
    UserModes.modes() |> Enum.map_join(&ModeRegistry.encode!(:user, &1))
  end

  @spec format_case_mapping(:ascii | :rfc1459 | :strict_rfc1459) :: String.t()
  defp format_case_mapping(:strict_rfc1459), do: "strict-rfc1459"
  defp format_case_mapping(case_mapping), do: to_string(case_mapping)

  @spec format_prefix() :: String.t()
  defp format_prefix do
    "(ov)@+"
  end

  @spec format_chanmodes() :: String.t()
  defp format_chanmodes do
    Enum.map_join([:a, :b, :c, :d], ",", fn type ->
      ChannelModes.mode_types()
      |> Enum.filter(fn {_mode, mode_type} -> mode_type == type end)
      |> Enum.map_join(fn {mode, _type} -> ModeRegistry.encode!(:channel, mode) end)
    end)
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
  defp format_feature(:boolean, _name, false), do: nil
  defp format_feature(:boolean, name, true), do: name

  @spec format_monitor_feature() :: String.t() | nil
  defp format_monitor_feature do
    if Monitor.enabled?() do
      monitor_config = Application.fetch_env!(:elixircd, :monitor)
      max_targets = Keyword.fetch!(monitor_config, :max_targets)

      if max_targets > 0 do
        "MONITOR=#{max_targets}"
      else
        "MONITOR"
      end
    else
      nil
    end
  end

  @spec format_maxlist(map()) :: String.t()
  defp format_maxlist(max_entries) do
    max_entries
    |> Enum.sort_by(fn {mode, _limit} -> to_string(mode) end)
    |> Enum.map_join(",", fn {mode, limit} -> "#{mode}:#{limit}" end)
  end

  @spec monitor_max_targets() :: non_neg_integer()
  defp monitor_max_targets do
    Application.fetch_env!(:elixircd, :monitor)
    |> Keyword.fetch!(:max_targets)
  end
end
