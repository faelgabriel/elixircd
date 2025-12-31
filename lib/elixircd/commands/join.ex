defmodule ElixIRCd.Commands.Join do
  @moduledoc """
  This module defines the JOIN command.

  JOIN allows users to join one or more channels.
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.MessageFilter, only: [filter_auditorium_users: 3]

  import ElixIRCd.Utils.Protocol,
    only: [user_mask: 1, channel_name?: 1, channel_operator?: 1, match_user_mask?: 2, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type channel_states :: :created | :existing
  @type mode :: String.t() | {String.t(), String.t()}
  @type mode_error ::
          :channel_key_invalid
          | :channel_limit_reached
          | :user_banned
          | :user_not_invited
          | :user_not_operator
          | :join_throttled
          | :user_not_registered
          | :connection_not_secure

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "JOIN"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: []}) do
    %Message{command: :err_needmoreparams, params: [user.nick, "JOIN"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: [channel_names | values]}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.with_index()
    |> Enum.each(fn {channel_name, index} ->
      join_value = Enum.at(values, index, nil)
      handle_join_channel(user, channel_name, join_value)
    end)
  end

  @spec handle_join_channel(User.t(), String.t(), String.t() | nil) :: :ok
  defp handle_join_channel(user, channel_name, join_value) do
    with :ok <- validate_channel_name(channel_name),
         :ok <- check_user_channel_limit(user, channel_name),
         {channel_state, channel} <- get_or_create_channel(channel_name),
         :ok <- check_modes(channel_state, channel, user, join_value) do
      user_channel =
        UserChannels.create(%{
          user_pid: user.pid,
          channel_name_key: channel.name_key,
          modes: determine_user_channel_modes(channel_state)
        })

      send_join_channel(user, channel, user_channel)
    else
      {:error, error} -> send_join_channel_error(error, user, channel_name)
    end
  end

  @spec get_or_create_channel(String.t()) :: {channel_states(), Channel.t()}
  defp get_or_create_channel(channel_name) do
    Channels.get_by_name(channel_name)
    |> case do
      {:ok, channel} ->
        {:existing, channel}

      _ ->
        channel = Channels.create(%{name: channel_name, topic: nil})
        {:created, channel}
    end
  end

  @spec determine_user_channel_modes(channel_states()) :: [String.t()]
  defp determine_user_channel_modes(:created), do: ["o"]
  defp determine_user_channel_modes(:existing), do: []

  @spec send_join_channel(User.t(), Channel.t(), UserChannel.t()) :: :ok
  defp send_join_channel(user, channel, user_channel) do
    user_channels =
      UserChannels.get_by_channel_name(channel.name)
      |> filter_auditorium_users(user_channel, channel.modes)

    user_pids = Enum.map(user_channels, & &1.user_pid)
    users = Users.get_by_pids(user_pids)

    {users_with_extended_join, users_without_extended_join} =
      Enum.split_with(users, fn u -> "EXTENDED-JOIN" in u.capabilities end)

    unless Enum.empty?(users_without_extended_join) do
      %Message{command: "JOIN", params: [channel.name]}
      |> Dispatcher.broadcast(user, users_without_extended_join)
    end

    unless Enum.empty?(users_with_extended_join) do
      account = user.identified_as || "*"

      %Message{command: "JOIN", params: [channel.name, account], trailing: user.realname}
      |> Dispatcher.broadcast(user, users_with_extended_join)
    end

    if channel_operator?(user_channel) do
      %Message{command: "MODE", params: [channel.name, "+o", user.nick]}
      |> Dispatcher.broadcast(:server, users)
    end

    {topic_reply, topic_trailing} =
      case channel.topic do
        nil -> {:rpl_notopic, "No topic is set"}
        %{text: topic_text} -> {:rpl_topic, topic_text}
      end

    [
      %Message{command: topic_reply, params: [user.nick, channel.name], trailing: topic_trailing},
      %Message{
        command: :rpl_namreply,
        params: ["=", user.nick, channel.name],
        trailing: get_user_channels_nicks(user, user_channels)
      },
      %Message{command: :rpl_endofnames, params: [user.nick, channel.name], trailing: "End of NAMES list."}
    ]
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_join_channel_error(mode_error() | String.t(), User.t(), String.t()) :: :ok
  defp send_join_channel_error(:channel_key_invalid, user, channel_name) do
    %Message{
      command: :err_badchannelkey,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel (+k) - bad key"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:channel_limit_reached, user, channel_name) do
    %Message{
      command: :err_channelisfull,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel (+l) - channel is full"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:channel_limit_per_prefix_reached, user, channel_name) do
    prefix = String.first(channel_name)
    channel_join_limits = Application.get_env(:elixircd, :channel)[:channel_join_limits] || %{"#" => 20, "&" => 10}
    max_channels = Map.get(channel_join_limits, prefix)

    %Message{
      command: :err_toomanychannels,
      params: [user.nick, channel_name],
      trailing: "You have reached the maximum number of #{prefix}-channels (#{max_channels})"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:user_banned, user, channel_name) do
    %Message{
      command: :err_bannedfromchan,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel (+b) - you are banned"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:user_not_invited, user, channel_name) do
    %Message{
      command: :err_inviteonlychan,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel (+i) - you are not invited"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:user_not_operator, user, channel_name) do
    %Message{
      command: :err_ircoperonlychan,
      params: [user.nick, channel_name],
      trailing: "Only IRC operators may join this channel (+O)"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:join_throttled, user, channel_name) do
    %Message{
      command: :err_needreggednick,
      params: [user.nick, channel_name],
      trailing: "Channel join rate exceeded (+j)"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:user_not_registered, user, channel_name) do
    %Message{
      command: :err_needreggednick,
      params: [user.nick, channel_name],
      trailing: "You must be identified to join this channel (+R)"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:connection_not_secure, user, channel_name) do
    %Message{
      command: :err_secureonlychan,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel - SSL/TLS required (+z)"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(error, user, channel_name) do
    %Message{command: :err_badchanmask, params: [user.nick, channel_name], trailing: "Cannot join channel - #{error}"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec validate_channel_name(String.t()) :: :ok | {:error, String.t()}
  defp validate_channel_name(channel_name) do
    chantypes = Application.get_env(:elixircd, :channel)[:channel_prefixes] || ["#", "&"]
    name_length = Application.get_env(:elixircd, :channel)[:max_channel_name_length] || 64

    cond do
      !channel_name?(channel_name) ->
        valid_prefixes = Enum.join(chantypes, " or ")
        {:error, "channel name must start with #{valid_prefixes}"}

      !valid_name_format?(channel_name) ->
        {:error, "invalid channel name format"}

      !valid_name_length?(channel_name, name_length) ->
        {:error, "channel name must be less or equal to #{name_length} characters"}

      true ->
        :ok
    end
  end

  @spec valid_name_format?(String.t()) :: boolean()
  defp valid_name_format?(channel_name) do
    normalized_channel_name = String.slice(channel_name, 1..-1//1)
    Regex.match?(~r/^[a-zA-Z0-9_\-]+$/, normalized_channel_name)
  end

  @spec valid_name_length?(String.t(), non_neg_integer()) :: boolean()
  defp valid_name_length?(channel_name, name_length) do
    normalized_channel_name = String.slice(channel_name, 1..-1//1)
    String.length(normalized_channel_name) <= name_length
  end

  @spec check_modes(channel_states(), Channel.t(), User.t(), String.t() | nil) :: :ok | {:error, mode_error()}
  defp check_modes(:created, _channel, _user, _join_value), do: :ok

  defp check_modes(:existing, channel, user, join_value) do
    with :ok <- check_user_banned(channel, user),
         :ok <- check_user_invited(channel, user),
         :ok <- check_registered_only_join(channel, user),
         :ok <- check_secure_only(channel, user),
         :ok <- check_channel_key(channel, user, join_value),
         :ok <- check_channel_limit(channel, user),
         :ok <- check_join_throttle(channel, user) do
      check_operator_only(channel, user)
    end
  end

  @spec check_user_banned(Channel.t(), User.t()) :: :ok | {:error, :user_banned}
  defp check_user_banned(channel, user) do
    is_banned =
      ChannelBans.get_by_channel_name_key(channel.name_key)
      |> Enum.any?(&match_user_mask?(user, &1.mask))

    is_excepted =
      ChannelExcepts.get_by_channel_name_key(channel.name_key)
      |> Enum.any?(&match_user_mask?(user, &1.mask))

    cond do
      not is_banned -> :ok
      is_excepted -> :ok
      true -> {:error, :user_banned}
    end
  end

  @spec check_user_invited(Channel.t(), User.t()) :: :ok | {:error, :user_not_invited}
  defp check_user_invited(channel, user) do
    if "i" in channel.modes do
      has_direct_invite =
        match?({:ok, _}, ChannelInvites.get_by_user_pid_and_channel_name(user.pid, channel.name))

      has_invex_exception =
        ChannelInvexes.get_by_channel_name_key(channel.name_key)
        |> Enum.any?(&match_user_mask?(user, &1.mask))

      if has_direct_invite or has_invex_exception do
        :ok
      else
        {:error, :user_not_invited}
      end
    else
      :ok
    end
  end

  @spec check_channel_key(Channel.t(), User.t(), String.t()) :: :ok | {:error, :channel_key_invalid}
  defp check_channel_key(channel, _user, key) do
    channel.modes
    |> Enum.find_value(fn
      {"k", value} -> value
      _ -> nil
    end)
    |> case do
      nil -> :ok
      channel_key when channel_key == key -> :ok
      _ -> {:error, :channel_key_invalid}
    end
  end

  @spec check_channel_limit(Channel.t(), User.t()) :: :ok | {:error, :channel_limit_reached}
  defp check_channel_limit(channel, _user) do
    channel.modes
    |> Enum.find_value(fn
      {"l", value} -> String.to_integer(value)
      _ -> nil
    end)
    |> case do
      nil ->
        :ok

      channel_limit ->
        case UserChannels.count_users_by_channel_name(channel.name) do
          channel_count when channel_count >= channel_limit -> {:error, :channel_limit_reached}
          _ -> :ok
        end
    end
  end

  @spec get_user_channels_nicks(User.t(), [UserChannel.t()]) :: String.t()
  defp get_user_channels_nicks(requesting_user, user_channels) do
    users_by_pid =
      Enum.map(user_channels, & &1.user_pid)
      |> Users.get_by_pids()
      |> Map.new(fn user -> {user.pid, user} end)

    use_extended_names = "UHNAMES" in requesting_user.capabilities

    user_channels
    |> Enum.map(fn user_channel ->
      user = Map.get(users_by_pid, user_channel.user_pid)
      {user, user_channel}
    end)
    |> Enum.sort_by(fn {_user, user_channel} -> user_channel.created_at end, :desc)
    |> Enum.map_join(" ", fn {user, user_channel} ->
      prefix = user_mode_symbol(user_channel)
      prefix <> format_user_for_join(user, use_extended_names)
    end)
  end

  @spec user_mode_symbol(UserChannel.t()) :: String.t()
  defp user_mode_symbol(%UserChannel{modes: modes}) do
    cond do
      Enum.member?(modes, "o") -> "@"
      Enum.member?(modes, "v") -> "+"
      true -> ""
    end
  end

  @spec format_user_for_join(User.t(), boolean()) :: String.t()
  defp format_user_for_join(user, true = _use_extended_names), do: user_mask(user)
  defp format_user_for_join(user, false = _use_extended_names), do: user.nick

  @spec check_user_channel_limit(User.t(), String.t()) :: :ok | {:error, :channel_limit_per_prefix_reached}
  defp check_user_channel_limit(user, channel_name) do
    prefix = String.first(channel_name)
    channel_join_limits = Application.get_env(:elixircd, :channel)[:channel_join_limits] || %{"#" => 20, "&" => 10}

    channels_with_prefix =
      UserChannels.get_by_user_pid(user.pid)
      |> Enum.count(fn uc ->
        String.starts_with?(uc.channel_name_key, prefix)
      end)

    max_channels = Map.get(channel_join_limits, prefix)

    if channels_with_prefix >= max_channels do
      {:error, :channel_limit_per_prefix_reached}
    else
      :ok
    end
  end

  @spec check_operator_only(Channel.t(), User.t()) :: :ok | {:error, :user_not_operator}
  defp check_operator_only(channel, user) do
    if "O" in channel.modes and not irc_operator?(user) do
      {:error, :user_not_operator}
    else
      :ok
    end
  end

  @spec check_join_throttle(Channel.t(), User.t()) :: :ok | {:error, :join_throttled}
  defp check_join_throttle(channel, user) do
    if irc_operator?(user) do
      :ok
    else
      apply_join_throttle_check(channel)
    end
  end

  @spec apply_join_throttle_check(Channel.t()) :: :ok | {:error, :join_throttled}
  defp apply_join_throttle_check(channel) do
    throttle_value = get_join_throttle_value(channel.modes)

    case throttle_value do
      nil -> :ok
      value -> validate_join_throttle(channel.name, value)
    end
  end

  @spec get_join_throttle_value([mode()]) :: String.t() | nil
  defp get_join_throttle_value(modes) do
    Enum.find_value(modes, fn
      {"j", value} -> value
      _ -> nil
    end)
  end

  @spec validate_join_throttle(String.t(), String.t()) :: :ok | {:error, :join_throttled}
  defp validate_join_throttle(channel_name, throttle_value) do
    [joins_str, seconds_str] = String.split(throttle_value, ":")
    max_joins = String.to_integer(joins_str)
    time_window = String.to_integer(seconds_str)

    since_time = DateTime.utc_now() |> DateTime.add(-time_window, :second)
    recent_joins = UserChannels.count_recent_joins_by_channel_name(channel_name, since_time)

    if recent_joins >= max_joins do
      {:error, :join_throttled}
    else
      :ok
    end
  end

  @spec check_registered_only_join(Channel.t(), User.t()) :: :ok | {:error, :user_not_registered}
  defp check_registered_only_join(channel, user) do
    if "R" in channel.modes and "r" not in user.modes do
      {:error, :user_not_registered}
    else
      :ok
    end
  end

  @spec check_secure_only(Channel.t(), User.t()) :: :ok | {:error, :connection_not_secure}
  defp check_secure_only(channel, user) do
    if "z" in channel.modes and "Z" not in user.modes do
      {:error, :connection_not_secure}
    else
      :ok
    end
  end
end
