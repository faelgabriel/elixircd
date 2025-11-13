defmodule ElixIRCd.Commands.Who do
  @moduledoc """
  This module defines the WHO command.

  WHO returns information about users matching specified criteria.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, user_reply: 1, normalize_mask: 1, irc_operator?: 1]

  alias ElixIRCd.Commands.Mode
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "WHO"}) do
    Message.build(%{command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "WHO", params: []}) do
    Message.build(%{
      command: :err_needmoreparams,
      params: [user_reply(user), "WHO"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "WHO", params: [target | filters]}) do
    case channel_name?(target) do
      true -> handle_who_channel(user, target, filters)
      false -> handle_who_mask(user, target, filters)
    end

    Message.build(%{
      command: :rpl_endofwho,
      params: [user.nick, target],
      trailing: "End of WHO list"
    })
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_who_channel(User.t(), String.t(), [String.t()]) :: :ok
  defp handle_who_channel(user, channel_name, filters) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} ->
        process_channel_who(user, channel, filters)

      {:error, :channel_not_found} ->
        :ok
    end
  end

  @spec process_channel_who(User.t(), Channel.t(), [String.t()]) :: :ok
  defp process_channel_who(user, channel, filters) do
    user_channels_list = UserChannels.get_by_channel_name(channel.name_key)

    if user_channels_list == [] do
      :ok
    else
      users_in_channel = Enum.map(user_channels_list, & &1.user_pid) |> Users.get_by_pids()
      user_shares_channel? = Enum.any?(users_in_channel, &(&1.pid == user.pid))

      channel_map = build_channel_map(user_channels_list)

      users_in_channel
      |> filter_out_hidden_channel(channel, user_shares_channel?)
      |> filter_out_invisible_users_for_channel(user_shares_channel?)
      |> filter_out_hidden_users_for_channel(user, user_shares_channel?)
      |> maybe_filter_operators(filters)
      |> Enum.map(fn user_target ->
        user_channel = Enum.find(user_channels_list, fn uc -> uc.user_pid == user_target.pid end)
        build_message(user, user_target, user_channel, channel, channel_map)
      end)
      |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec handle_who_mask(User.t(), String.t(), [String.t()]) :: :ok
  defp handle_who_mask(user, mask, filters) do
    user_pids_sharing_channels_keys = get_user_shared_channel_pids(user)

    users =
      normalize_mask(mask)
      |> Users.get_by_match_mask()
      |> filter_out_invisible_users_for_mask(user_pids_sharing_channels_keys)
      |> filter_out_hidden_users_for_mask(user, user_pids_sharing_channels_keys)
      |> maybe_filter_operators(filters)

    # Early return if no users match
    if users == [] do
      :ok
    else
      process_mask_who(user, users, user_pids_sharing_channels_keys)
    end
  end

  @spec get_user_shared_channel_pids(User.t()) :: [pid()]
  defp get_user_shared_channel_pids(user) do
    UserChannels.get_by_user_pid(user.pid)
    |> Enum.map(& &1.channel_name_key)
    |> UserChannels.get_by_channel_names()
    |> Enum.map(& &1.user_pid)
    |> Enum.uniq()
  end

  @spec process_mask_who(User.t(), [User.t()], [pid()]) :: :ok
  defp process_mask_who(user, users, user_pids_sharing_channels_keys) do
    user_channels_by_pid =
      Enum.map(users, & &1.pid)
      |> UserChannels.get_by_user_pids()
      |> Enum.group_by(& &1.user_pid, & &1)

    channel_map = build_channel_map_from_user_channels(user_channels_by_pid)

    users
    |> Enum.map(fn user_target ->
      user_channel_for_mask_target =
        get_visible_channel_for_mask(user_target, users, user_channels_by_pid, user_pids_sharing_channels_keys)

      build_message(user, user_target, user_channel_for_mask_target, nil, channel_map)
    end)
    |> Dispatcher.broadcast(:server, user)
  end

  @spec get_visible_channel_for_mask(User.t(), [User.t()], map(), [pid()]) :: UserChannel.t() | nil
  defp get_visible_channel_for_mask(user_target, users, user_channels_by_pid, user_pids_sharing_channels_keys) do
    case length(users) == 1 do
      true ->
        user_channels_by_pid[user_target.pid]
        |> filter_not_hidden_channel(user_pids_sharing_channels_keys)

      false ->
        nil
    end
  end

  @spec build_channel_map([UserChannel.t()]) :: map()
  defp build_channel_map(user_channels_list) do
    user_channels_list
    |> Enum.map(& &1.channel_name_key)
    |> Enum.uniq()
    |> build_channel_map_from_keys()
  end

  @spec build_channel_map_from_user_channels(map()) :: map()
  defp build_channel_map_from_user_channels(user_channels_by_pid) do
    Enum.flat_map(user_channels_by_pid, fn {_pid, user_channels} ->
      Enum.map(user_channels, & &1.channel_name_key)
    end)
    |> Enum.uniq()
    |> build_channel_map_from_keys()
  end

  @spec build_channel_map_from_keys([String.t()]) :: map()
  defp build_channel_map_from_keys(channel_keys) do
    if channel_keys == [] do
      %{}
    else
      channel_keys
      |> Channels.get_by_names()
      |> Enum.into(%{}, fn ch -> {ch.name_key, ch} end)
    end
  end

  @spec filter_out_invisible_users_for_channel([User.t()], boolean()) :: [User.t()]
  defp filter_out_invisible_users_for_channel(users, user_shares_channel?) do
    users
    |> Enum.reject(&("i" in &1.modes and !user_shares_channel?))
  end

  @spec filter_out_invisible_users_for_mask([User.t()], [pid()]) :: [User.t()]
  defp filter_out_invisible_users_for_mask(users, user_pids_sharing_channels_keys) do
    users
    |> Enum.reject(&("i" in &1.modes and &1.pid not in user_pids_sharing_channels_keys))
  end

  @spec filter_out_hidden_users_for_channel([User.t()], User.t(), boolean()) :: [User.t()]
  defp filter_out_hidden_users_for_channel(users, requesting_user, user_shares_channel?) do
    users
    |> Enum.reject(&("H" in &1.modes and !irc_operator?(requesting_user) and !user_shares_channel?))
  end

  @spec filter_out_hidden_users_for_mask([User.t()], User.t(), [pid()]) :: [User.t()]
  defp filter_out_hidden_users_for_mask(users, requesting_user, user_pids_sharing_channels_keys) do
    users
    |> Enum.reject(
      &("H" in &1.modes and !irc_operator?(requesting_user) and &1.pid not in user_pids_sharing_channels_keys)
    )
  end

  @spec filter_out_hidden_channel([User.t()], Channel.t(), boolean()) :: [User.t()]
  defp filter_out_hidden_channel(users, channel, user_shares_channel?) do
    if !user_shares_channel? and "s" in channel.modes do
      []
    else
      users
    end
  end

  @spec filter_not_hidden_channel([UserChannel.t()] | nil, [pid()]) :: UserChannel.t() | nil
  defp filter_not_hidden_channel(user_channels_list, user_pids_sharing_channels_keys)
       when user_channels_list not in [nil, []] do
    channel_map = build_channel_visibility_map(user_channels_list)
    find_visible_channel(user_channels_list, user_pids_sharing_channels_keys, channel_map)
  end

  defp filter_not_hidden_channel(nil, _user_pids_sharing_channels_keys), do: nil

  @spec build_channel_visibility_map([UserChannel.t()]) :: map()
  defp build_channel_visibility_map(user_channels_list) do
    channel_name_keys =
      user_channels_list
      |> Enum.map(& &1.channel_name_key)
      |> Enum.uniq()

    channel_name_keys
    |> Channels.get_by_names()
    |> Map.new(fn channel -> {channel.name_key, channel} end)
  end

  @spec find_visible_channel([UserChannel.t()], [pid()], map()) :: UserChannel.t() | nil
  defp find_visible_channel(user_channels_list, user_pids_sharing_channels_keys, channel_map) do
    Enum.find(user_channels_list, fn user_channel ->
      user_shares_channel? = user_channel.user_pid in user_pids_sharing_channels_keys

      user_shares_channel? or
        case Map.get(channel_map, user_channel.channel_name_key) do
          nil -> false
          channel -> "s" not in channel.modes
        end
    end)
  end

  @spec maybe_filter_operators([User.t()], [String.t()]) :: [User.t()]
  defp maybe_filter_operators(users, filters) do
    case filter_operators?(filters) do
      true -> Enum.filter(users, &("o" in &1.modes))
      false -> users
    end
  end

  @spec build_message(User.t(), User.t(), UserChannel.t() | nil, Channel.t() | nil, map()) :: Message.t()
  defp build_message(user, user_target, user_channel, channel, channel_map) do
    user_channel_name = resolve_channel_name(user_channel, channel, channel_map)

    Message.build(%{
      command: :rpl_whoreply,
      params: [
        user_reply(user),
        user_channel_name,
        user_target.ident,
        user_target.hostname,
        Application.get_env(:elixircd, :server)[:hostname],
        user_target.nick,
        user_statuses(user, user_target, user_channel)
      ],
      trailing: "0 #{user_target.realname}"
    })
  end

  @spec resolve_channel_name(UserChannel.t() | nil, Channel.t() | nil, map()) :: String.t()
  defp resolve_channel_name(user_channel, channel, channel_map) do
    cond do
      channel != nil ->
        channel.name

      !is_nil(user_channel) and Map.has_key?(channel_map, user_channel.channel_name_key) ->
        Map.get(channel_map, user_channel.channel_name_key).name

      true ->
        "*"
    end
  end

  @spec user_statuses(User.t(), User.t(), UserChannel.t() | nil) :: String.t()
  defp user_statuses(requesting_user, user_target, user_channel) do
    use_extended_uhlist = "EXTENDED-UHLIST" in requesting_user.capabilities

    base_status =
      user_away_status(user_target) <>
        irc_operator_symbol(user_target) <>
        channel_operator_symbol(user_channel) <>
        channel_voice_symbol(user_channel)

    if use_extended_uhlist do
      base_status <> extended_user_modes(requesting_user, user_target)
    else
      base_status
    end
  end

  @spec extended_user_modes(User.t(), User.t()) :: String.t()
  defp extended_user_modes(requesting_user, %User{modes: modes}) do
    modes_restricted_to_operators = Mode.UserModes.modes_restricted_to_operators()
    extended_modes = modes -- ["o"]

    filtered_modes =
      if irc_operator?(requesting_user) do
        extended_modes
      else
        extended_modes -- modes_restricted_to_operators
      end

    Enum.join(filtered_modes, "")
  end

  @spec user_away_status(User.t()) :: String.t()
  defp user_away_status(%User{} = user), do: if(user.away_message != nil, do: "G", else: "H")

  @spec irc_operator_symbol(User.t()) :: String.t()
  defp irc_operator_symbol(%User{modes: modes}), do: if("o" in modes, do: "*", else: "")

  @spec channel_operator_symbol(UserChannel.t() | nil) :: String.t()
  defp channel_operator_symbol(%UserChannel{modes: modes}), do: if("o" in modes, do: "@", else: "")
  defp channel_operator_symbol(_user_channel), do: ""

  @spec channel_voice_symbol(UserChannel.t() | nil) :: String.t()
  defp channel_voice_symbol(%UserChannel{modes: modes}), do: if("v" in modes, do: "+", else: "")
  defp channel_voice_symbol(_user_channel), do: ""

  @spec filter_operators?([String.t()]) :: boolean()
  defp filter_operators?([filter | _]) do
    filter
    |> String.downcase()
    |> String.contains?("o")
  end

  defp filter_operators?(_filters), do: false
end
