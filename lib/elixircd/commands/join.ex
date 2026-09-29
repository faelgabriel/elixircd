defmodule ElixIRCd.Commands.Join do
  @moduledoc """
  This module defines the JOIN command.

  JOIN allows users to join one or more channels.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter, only: [filter_auditorium_users: 3]
  import ElixIRCd.Utils.Nickserv, only: [account_setting: 3]

  import ElixIRCd.Utils.Protocol,
    only: [
      user_mask: 1,
      channel_name?: 1,
      channel_operator?: 1,
      match_user_mask?: 2,
      irc_operator?: 1,
      chunk_message_words: 2
    ]

  alias ElixIRCd.Commands.Names
  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Metadata
  alias ElixIRCd.ReadMarkers
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelAdoption
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.Service
  alias ElixIRCd.Services.Chanserv.Akick
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Chanserv.Flags
  alias ElixIRCd.Utils.Chanserv.ModeLock

  @type channel_states :: :created | :adopted | :existing
  @type mode :: ElixIRCd.ModeRegistry.channel_mode() | {ElixIRCd.ModeRegistry.channel_mode(), String.t()}
  @type mode_error ::
          :channel_key_invalid
          | :channel_limit_reached
          | :user_banned
          | :user_not_invited
          | :user_not_operator
          | :join_throttled
          | :user_not_registered
          | :connection_not_secure
          | :registered_channel_restricted

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
    keys = values |> List.first("") |> String.split(",")

    channel_names
    |> String.split(",")
    |> Enum.with_index()
    |> Enum.each(fn {channel_name, index} ->
      join_value = Enum.at(keys, index, nil)
      handle_join_channel(user, channel_name, join_value)
    end)
  end

  @spec handle_join_channel(User.t(), String.t(), String.t() | nil) :: :ok
  defp handle_join_channel(user, channel_name, join_value) do
    with :ok <- validate_channel_name(channel_name),
         {:error, :user_channel_not_found} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name),
         :ok <- check_user_channel_limit(user, channel_name),
         {:ok, network_view} <- network_channel_view(channel_name),
         {channel_state, %Channel{} = channel} <- get_or_create_channel(channel_name, network_view),
         channel <- maybe_apply_registered_mode_lock(channel, network_view) do
      case check_modes(channel_state, channel, user, join_value, network_view) do
        :ok ->
          complete_join(user, channel_state, channel, network_view)

        {:error, error} ->
          rollback_created_channel(channel_state, channel)
          send_join_channel_error(error, user, channel_name)
      end
    else
      {:ok, _existing_membership} -> :ok
      {:error, error} -> send_join_channel_error(error, user, channel_name)
    end
  end

  defp network_channel_view(channel_name) do
    links_enabled? = Application.fetch_env!(:elixircd, :server_links)[:enabled]

    case ChannelDirectory.get(channel_name) do
      {:ok, %ChannelView{remote_present: true} = view} -> {:ok, view}
      :unavailable when links_enabled? -> {:error, :remote_channel_unavailable}
      :error when links_enabled? -> unindexed_channel_view(channel_name)
      _ -> {:ok, nil}
    end
  end

  defp unindexed_channel_view(channel_name) do
    case Channels.get_by_name(channel_name) do
      {:ok, %Channel{}} -> {:error, :remote_channel_unavailable}
      {:error, :channel_not_found} -> {:ok, nil}
    end
  end

  defp complete_join(user, channel_state, channel, network_view) do
    modes =
      if is_nil(network_view) and recovery_invite?(channel, user),
        do: [:o],
        else: determine_user_channel_modes(channel_state)

    user_channel =
      UserChannels.create(%{
        user_pid: user.pid,
        channel_name_key: channel.name_key,
        modes: modes
      })

    ChannelInvites.delete_by_user_pid_and_channel_name(user.pid, channel.name)
    send_join_channel(user, channel, user_channel, network_view)
  end

  @spec rollback_created_channel(channel_states(), Channel.t()) :: :ok
  defp rollback_created_channel(:created, channel), do: Channels.delete(channel)
  defp rollback_created_channel(:adopted, channel), do: Channels.delete(channel)
  defp rollback_created_channel(:existing, _channel), do: :ok

  @spec get_or_create_channel(String.t(), ChannelView.t() | nil) :: {channel_states(), Channel.t()} | {:error, atom()}
  defp get_or_create_channel(channel_name, view) when not is_nil(view),
    do: ChannelAdoption.get_or_create(channel_name, view)

  defp get_or_create_channel(channel_name, nil) do
    Channels.get_by_name(channel_name)
    |> case do
      {:ok, channel} ->
        {:existing, channel}

      _ ->
        channel = Channels.create(%{name: channel_name, topic: restored_topic(channel_name)})
        {:created, channel}
    end
  end

  defp maybe_apply_registered_mode_lock(channel, nil), do: apply_registered_mode_lock(channel)
  defp maybe_apply_registered_mode_lock(channel, _network_view), do: channel

  @spec apply_registered_mode_lock(Channel.t()) :: Channel.t()
  defp apply_registered_mode_lock(channel) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, registered_channel} ->
        {updated_channel, _applied_changes} = ModeLock.reconcile_and_broadcast(channel, registered_channel)
        updated_channel

      {:error, :registered_channel_not_found} ->
        channel
    end
  end

  @spec restored_topic(String.t()) :: Channel.Topic.t() | nil
  defp restored_topic(channel_name) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, %{settings: settings, topic: topic}} when settings.keeptopic or settings.topiclock ->
        restore_persistent_topic(settings.persistent_topic, topic)

      {:ok, _registered_channel} ->
        nil

      {:error, :registered_channel_not_found} ->
        nil
    end
  end

  @spec restore_persistent_topic(String.t() | nil, Channel.Topic.t() | nil) :: Channel.Topic.t() | nil
  defp restore_persistent_topic(nil, topic), do: topic

  defp restore_persistent_topic(persistent_topic, nil) do
    %Channel.Topic{
      text: persistent_topic,
      setter: Service.mask(:chanserv),
      set_at: DateTime.utc_now()
    }
  end

  defp restore_persistent_topic(persistent_topic, %Channel.Topic{text: persistent_topic} = topic), do: topic

  defp restore_persistent_topic(persistent_topic, topic) do
    %{topic | text: persistent_topic, setter: Service.mask(:chanserv), set_at: DateTime.utc_now()}
  end

  @spec determine_user_channel_modes(channel_states()) :: [ElixIRCd.ModeRegistry.membership_mode()]
  defp determine_user_channel_modes(:created), do: [:o]
  defp determine_user_channel_modes(:adopted), do: []
  defp determine_user_channel_modes(:existing), do: []

  @spec send_join_channel(User.t(), Channel.t(), UserChannel.t(), ChannelView.t() | nil) :: :ok
  defp send_join_channel(user, channel, user_channel, network_view) do
    user_channels =
      UserChannels.get_by_channel_name(channel.name)
      |> filter_auditorium_users(user_channel, channel.modes)

    user_pids = Enum.map(user_channels, & &1.user_pid)
    users = Users.get_by_pids(user_pids)

    {users_with_extended_join, users_without_extended_join} =
      Enum.split_with(users, fn u -> "extended-join" in u.capabilities end)

    unless Enum.empty?(users_without_extended_join) do
      %Message{command: "JOIN", params: [channel.name]}
      |> Dispatcher.broadcast(user, users_without_extended_join)
    end

    unless Enum.empty?(users_with_extended_join) do
      account = user.identified_as || "*"

      %Message{command: "JOIN", params: [channel.name, account], trailing: user.realname}
      |> Dispatcher.broadcast(user, users_with_extended_join)
    end

    History.record_channel_event(%Message{command: "JOIN", params: [channel.name]}, user, channel.name)

    if channel_operator?(user_channel) do
      %Message{command: "MODE", params: [channel.name, "+o", user.nick]}
      |> Dispatcher.broadcast(:server, users)
    end

    if user.away_message != nil do
      watchers = Enum.filter(users, &("away-notify" in &1.capabilities and &1.pid != user.pid))

      %Message{command: "AWAY", params: [], trailing: user.away_message}
      |> Dispatcher.broadcast(user, watchers)
    end

    Metadata.sync_join(user, channel, users)

    send_channel_state(user, channel, user_channels, network_view)

    send_entry_message(user, channel)
    send_operator_join_notice(user, channel, user_channels)
  end

  defp send_channel_state(user, channel, user_channels, nil) do
    channel_state_messages(user, channel, user_channels)
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_state(user, channel, _user_channels, _network_view) do
    build_topic_messages(user, channel)
    |> Dispatcher.broadcast(:server, user)

    if ReadMarkers.enabled?() and "draft/read-marker" in user.capabilities,
      do: Dispatcher.broadcast(ReadMarkers.message(user, channel.name), :server, user)

    Names.handle(user, %Message{command: "NAMES", params: [channel.name]})
  end

  @doc "Builds the replies sent after JOIN, also used by channel-rename fallback."
  @spec channel_state_messages(User.t(), Channel.t(), [UserChannel.t()]) :: [Message.t()]
  def channel_state_messages(user, channel, user_channels) do
    names_message = %Message{
      prefix: Dispatcher.server_prefix(),
      command: :rpl_namreply,
      params: [user.nick, channel_status(channel), channel.name]
    }

    read_marker_messages =
      if ReadMarkers.enabled?() and "draft/read-marker" in user.capabilities do
        [ReadMarkers.message(user, channel.name)]
      else
        []
      end

    build_topic_messages(user, channel) ++
      chunk_message_words(names_message, get_user_channels_nicks(user, user_channels)) ++
      read_marker_messages ++
      [%Message{command: :rpl_endofnames, params: [user.nick, channel.name], trailing: "End of NAMES list."}]
  end

  @spec send_entry_message(User.t(), Channel.t()) :: :ok
  defp send_entry_message(user, channel) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, registered_channel} ->
        entry_message = registered_channel.settings.entrymsg

        if is_binary(entry_message) and not account_setting(user.identified_as, :no_greet, false) do
          %Message{command: "NOTICE", params: [user.nick], trailing: entry_message}
          |> Dispatcher.broadcast(:chanserv, user)
        end

      {:error, :registered_channel_not_found} ->
        :ok
    end

    :ok
  end

  @spec send_operator_join_notice(User.t(), Channel.t(), [UserChannel.t()]) :: :ok
  defp send_operator_join_notice(user, channel, user_channels) do
    with {:ok, registered_channel} <- RegisteredChannels.get_by_name(channel.name),
         true <- Map.get(registered_channel.settings, :opnotice) == true do
      user_channels
      |> Enum.filter(&(:o in &1.modes and &1.user_pid != user.pid))
      |> Enum.map(& &1.user_pid)
      |> Users.get_by_pids()
      |> Enum.each(fn operator ->
        %Message{
          command: "NOTICE",
          params: [operator.nick],
          trailing: "#{user.nick} has joined #{channel.name}."
        }
        |> Dispatcher.broadcast(:chanserv, operator)
      end)
    else
      _ -> :ok
    end

    :ok
  end

  # RFC 2812: 332 is followed by 333 (who set the topic and when).
  @spec build_topic_messages(User.t(), Channel.t()) :: [Message.t()]
  defp build_topic_messages(_user, %{topic: nil}), do: []

  defp build_topic_messages(user, %{topic: topic} = channel) do
    topic_set_at = topic.set_at |> DateTime.to_unix() |> Integer.to_string()

    [
      %Message{command: :rpl_topic, params: [user.nick, channel.name], trailing: topic.text},
      %Message{
        command: :rpl_topicwhotime,
        params: [user.nick, channel.name, topic.setter, topic_set_at]
      }
    ]
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
    channel_join_limits = Application.fetch_env!(:elixircd, :channel)[:channel_join_limits]
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

  defp send_join_channel_error(:registered_channel_restricted, user, channel_name) do
    %Message{
      command: :err_needreggednick,
      params: [user.nick, channel_name],
      trailing: "You must be identified to an account with channel access (ChanServ RESTRICTED)"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(:remote_channel_unavailable, user, channel_name) do
    %Message{
      command: :err_unavailresource,
      params: [user.nick, channel_name],
      trailing: "Channel is temporarily unavailable on this server"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_join_channel_error(error, user, channel_name) do
    %Message{command: :err_badchanmask, params: [user.nick, channel_name], trailing: "Cannot join channel - #{error}"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec validate_channel_name(String.t()) :: :ok | {:error, String.t()}
  defp validate_channel_name(channel_name) do
    chantypes = Application.fetch_env!(:elixircd, :channel)[:channel_prefixes]
    name_length = Application.fetch_env!(:elixircd, :channel)[:max_channel_name_length]

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
    normalized_channel_name != "" and not String.contains?(channel_name, [" ", ",", ":", "\0", "\a", "\r", "\n"])
  end

  @spec valid_name_length?(String.t(), non_neg_integer()) :: boolean()
  defp valid_name_length?(channel_name, name_length) do
    normalized_channel_name = String.slice(channel_name, 1..-1//1)
    String.length(normalized_channel_name) <= name_length
  end

  @spec check_modes(channel_states(), Channel.t(), User.t(), String.t() | nil, ChannelView.t() | nil) ::
          :ok | {:error, mode_error()}
  defp check_modes(_channel_state, channel, user, join_value, network_view) do
    if is_nil(network_view) and recovery_invite?(channel, user) do
      with :ok <- check_secure_only(channel, user), do: check_operator_only(channel, user)
    else
      check_normal_modes(channel, user, join_value, network_view)
    end
  end

  defp check_normal_modes(channel, user, join_value, network_view) do
    with :ok <- check_user_banned(channel, user, network_view),
         :ok <- check_user_invited(channel, user, network_view),
         :ok <- check_registered_channel_restrictions(channel, user),
         :ok <- check_registered_only_join(channel, user),
         :ok <- check_secure_only(channel, user),
         :ok <- check_channel_key(channel, user, join_value),
         :ok <- check_channel_limit(channel, user, network_view),
         :ok <- check_join_throttle(channel, user, network_view) do
      check_operator_only(channel, user)
    end
  end

  defp recovery_invite?(channel, user) do
    with {:ok, registered} <- RegisteredChannels.get_by_name(channel.name),
         true <- Flags.founder?(registered, user.identified_as),
         {:ok, invite} <- ChannelInvites.get_by_user_pid_and_channel_name(user.pid, channel.name) do
      invite.bypass_ban == true and invite.setter == Service.mask(:chanserv)
    else
      _ -> false
    end
  end

  @spec check_registered_channel_restrictions(Channel.t(), User.t()) :: :ok | {:error, :registered_channel_restricted}
  defp check_registered_channel_restrictions(channel, user) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, registered_channel} ->
        settings = registered_channel.settings

        access_entries =
          registered_channel.name
          |> RegisteredChannelAccesses.get_flags_map_by_channel_name()
          |> Flags.normalize_access_entries()

        if Map.get(settings, :restricted) == true and
             not Flags.has_access?(registered_channel, user.identified_as, access_entries) do
          {:error, :registered_channel_restricted}
        else
          :ok
        end

      {:error, :registered_channel_not_found} ->
        :ok
    end
  end

  @spec check_user_banned(Channel.t(), User.t(), ChannelView.t() | nil) :: :ok | {:error, :user_banned}
  defp check_user_banned(channel, user, network_view) do
    is_banned =
      (ChannelBans.get_by_channel_name_key(channel.name_key) ++ network_lists(network_view, "b"))
      |> Enum.any?(&match_user_mask?(user, &1.mask))

    is_excepted =
      (ChannelExcepts.get_by_channel_name_key(channel.name_key) ++ network_lists(network_view, "e"))
      |> Enum.any?(&match_user_mask?(user, &1.mask))

    has_operator_invite =
      case ChannelInvites.get_by_user_pid_and_channel_name(user.pid, channel.name) do
        {:ok, invite} -> invite.bypass_ban == true
        {:error, :channel_invite_not_found} -> false
      end

    cond do
      Akick.blocked?(channel.name, user) -> {:error, :user_banned}
      not is_banned -> :ok
      is_excepted -> :ok
      has_operator_invite -> :ok
      true -> {:error, :user_banned}
    end
  end

  @spec check_user_invited(Channel.t(), User.t(), ChannelView.t() | nil) :: :ok | {:error, :user_not_invited}
  defp check_user_invited(channel, user, network_view) do
    if :i in channel.modes do
      has_invex_exception =
        (ChannelInvexes.get_by_channel_name_key(channel.name_key) ++ network_lists(network_view, "I"))
        |> Enum.any?(&match_user_mask?(user, &1.mask))

      if directly_invited?(channel, user) or has_invex_exception do
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
      {:k, value} -> value
      _ -> nil
    end)
    |> case do
      nil -> :ok
      channel_key when channel_key == key -> :ok
      _ -> {:error, :channel_key_invalid}
    end
  end

  @spec check_channel_limit(Channel.t(), User.t(), ChannelView.t() | nil) :: :ok | {:error, :channel_limit_reached}
  defp check_channel_limit(channel, user, network_view) do
    channel_limit =
      Enum.find_value(channel.modes, fn
        {:l, value} -> String.to_integer(value)
        _ -> nil
      end)

    cond do
      directly_invited?(channel, user) ->
        :ok

      is_nil(channel_limit) ->
        :ok

      UserChannels.count_users_by_channel_name(channel.name) + remote_member_count(network_view) >= channel_limit ->
        {:error, :channel_limit_reached}

      true ->
        :ok
    end
  end

  defp network_lists(nil, _kind), do: []

  defp network_lists(view, kind) do
    for %{effective: true, entry: %{"kind" => ^kind} = entry} <- view.remote_lists,
        do: %{mask: entry["mask"]}
  end

  defp remote_member_count(nil), do: 0
  defp remote_member_count(view), do: length(view.remote_members)

  @spec directly_invited?(Channel.t(), User.t()) :: boolean()
  defp directly_invited?(channel, user) do
    match?({:ok, _}, ChannelInvites.get_by_user_pid_and_channel_name(user.pid, channel.name))
  end

  @spec get_user_channels_nicks(User.t(), [UserChannel.t()]) :: [ElixIRCd.Utils.Protocol.word_choice()]
  defp get_user_channels_nicks(requesting_user, user_channels) do
    users_by_pid =
      Enum.map(user_channels, & &1.user_pid)
      |> Users.get_by_pids()
      |> Map.new(fn user -> {user.pid, user} end)

    use_extended_names = "userhost-in-names" in requesting_user.capabilities

    user_channels
    |> Enum.map(fn user_channel ->
      user = Map.get(users_by_pid, user_channel.user_pid)
      {user, user_channel}
    end)
    |> Enum.sort_by(fn {_user, user_channel} -> user_channel.created_at end, :desc)
    |> Enum.map(fn {user, user_channel} ->
      prefix = user_mode_symbol(user_channel, "multi-prefix" in requesting_user.capabilities)
      formatted_user = prefix <> format_user_for_join(user, use_extended_names)

      if use_extended_names do
        {formatted_user, prefix <> user.nick}
      else
        formatted_user
      end
    end)
  end

  @spec channel_status(Channel.t()) :: String.t()
  defp channel_status(channel) do
    cond do
      :s in channel.modes -> "@"
      :p in channel.modes -> "*"
      true -> "="
    end
  end

  @spec user_mode_symbol(UserChannel.t(), boolean()) :: String.t()
  defp user_mode_symbol(%UserChannel{modes: modes}, true) do
    Enum.map_join([{:o, "@"}, {:v, "+"}], fn {mode, prefix} -> if mode in modes, do: prefix, else: "" end)
  end

  defp user_mode_symbol(%UserChannel{modes: modes}, false) do
    cond do
      Enum.member?(modes, :o) -> "@"
      Enum.member?(modes, :v) -> "+"
      true -> ""
    end
  end

  @spec format_user_for_join(User.t(), boolean()) :: String.t()
  defp format_user_for_join(user, true = _use_extended_names), do: user_mask(user)
  defp format_user_for_join(user, false = _use_extended_names), do: user.nick

  @spec check_user_channel_limit(User.t(), String.t()) :: :ok | {:error, :channel_limit_per_prefix_reached}
  defp check_user_channel_limit(user, channel_name) do
    prefix = String.first(channel_name)
    channel_join_limits = Application.fetch_env!(:elixircd, :channel)[:channel_join_limits]

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
    if :O in channel.modes and not irc_operator?(user) do
      {:error, :user_not_operator}
    else
      :ok
    end
  end

  @spec check_join_throttle(Channel.t(), User.t(), ChannelView.t() | nil) :: :ok | {:error, :join_throttled}
  defp check_join_throttle(channel, user, network_view) do
    if irc_operator?(user) do
      :ok
    else
      apply_join_throttle_check(channel, network_view)
    end
  end

  @spec apply_join_throttle_check(Channel.t(), ChannelView.t() | nil) :: :ok | {:error, :join_throttled}
  defp apply_join_throttle_check(channel, network_view) do
    throttle_value = get_join_throttle_value(channel.modes)

    case throttle_value do
      nil -> :ok
      value -> validate_join_throttle(channel.name, value, network_view)
    end
  end

  @spec get_join_throttle_value([mode()]) :: String.t() | nil
  defp get_join_throttle_value(modes) do
    Enum.find_value(modes, fn
      {:j, value} -> value
      _ -> nil
    end)
  end

  @spec validate_join_throttle(String.t(), String.t(), ChannelView.t() | nil) :: :ok | {:error, :join_throttled}
  defp validate_join_throttle(channel_name, throttle_value, network_view) do
    [joins_str, seconds_str] = String.split(throttle_value, ":")
    max_joins = String.to_integer(joins_str)
    time_window = String.to_integer(seconds_str)

    since_time = DateTime.utc_now() |> DateTime.add(-time_window, :second)

    recent_joins =
      UserChannels.count_recent_joins_by_channel_name(channel_name, since_time) +
        recent_remote_joins(network_view, since_time)

    if recent_joins >= max_joins do
      {:error, :join_throttled}
    else
      :ok
    end
  end

  defp recent_remote_joins(nil, _since_time), do: 0

  defp recent_remote_joins(view, since_time) do
    Enum.count(view.remote_members, fn %{member: %{"joined_at" => joined_at}} ->
      case DateTime.from_iso8601(joined_at) do
        {:ok, time, _offset} -> DateTime.compare(time, since_time) != :lt
        _ -> false
      end
    end)
  end

  @spec check_registered_only_join(Channel.t(), User.t()) :: :ok | {:error, :user_not_registered}
  defp check_registered_only_join(channel, user) do
    if :R in channel.modes and :r not in user.modes do
      {:error, :user_not_registered}
    else
      :ok
    end
  end

  @spec check_secure_only(Channel.t(), User.t()) :: :ok | {:error, :connection_not_secure}
  defp check_secure_only(channel, user) do
    if :z in channel.modes and :Z not in user.modes do
      {:error, :connection_not_secure}
    else
      :ok
    end
  end
end
