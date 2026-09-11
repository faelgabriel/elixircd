defmodule ElixIRCd.Commands.Who do
  @moduledoc """
  This module defines the WHO command.

  WHO returns information about users matching specified criteria.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol,
    only: [channel_name?: 1, user_reply: 1, normalize_mask: 1, irc_operator?: 1, display_hostname: 2]

  import ElixIRCd.Utils.Network, only: [format_ip_address: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @whox_field_order ~w(t c u i h s n f d l a o r)

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "WHO"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "WHO", params: []}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "WHO"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "WHO", params: [target | filters]}) do
    query = parse_query(filters)

    case channel_name?(target) do
      true -> handle_who_channel(user, target, query)
      false -> handle_who_mask(user, target, query)
    end

    %Message{command: :rpl_endofwho, params: [user.nick, target], trailing: "End of WHO list"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_who_channel(User.t(), String.t(), map()) :: :ok
  defp handle_who_channel(user, channel_name, query) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} ->
        process_channel_who(user, channel, query)

      {:error, :channel_not_found} ->
        :ok
    end
  end

  @spec process_channel_who(User.t(), Channel.t(), map()) :: :ok
  defp process_channel_who(user, channel, query) do
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
      |> maybe_filter_operators(query)
      |> Enum.map(fn user_target ->
        user_channel = Enum.find(user_channels_list, fn uc -> uc.user_pid == user_target.pid end)
        build_message(user, user_target, user_channel, channel, channel_map, query)
      end)
      |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec handle_who_mask(User.t(), String.t(), map()) :: :ok
  defp handle_who_mask(user, mask, query) do
    user_pids_sharing_channels_keys = get_user_shared_channel_pids(user)

    users =
      normalize_mask(mask)
      |> Users.get_by_match_mask()
      |> filter_out_invisible_users_for_mask(user_pids_sharing_channels_keys)
      |> filter_out_hidden_users_for_mask(user, user_pids_sharing_channels_keys)
      |> maybe_filter_operators(query)

    # Early return if no users match
    if users == [] do
      :ok
    else
      process_mask_who(user, users, user_pids_sharing_channels_keys, query)
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

  @spec process_mask_who(User.t(), [User.t()], [pid()], map()) :: :ok
  defp process_mask_who(user, users, user_pids_sharing_channels_keys, query) do
    user_channels_by_pid =
      Enum.map(users, & &1.pid)
      |> UserChannels.get_by_user_pids()
      |> Enum.group_by(& &1.user_pid, & &1)

    channel_map = build_channel_map_from_user_channels(user_channels_by_pid)

    users
    |> Enum.map(fn user_target ->
      user_channel_for_mask_target =
        get_visible_channel_for_mask(user_target, users, user_channels_by_pid, user_pids_sharing_channels_keys)

      build_message(user, user_target, user_channel_for_mask_target, nil, channel_map, query)
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

  @spec maybe_filter_operators([User.t()], map()) :: [User.t()]
  defp maybe_filter_operators(users, query) do
    case query.operator_only do
      true -> Enum.filter(users, &("o" in &1.modes))
      false -> users
    end
  end

  @spec build_message(User.t(), User.t(), UserChannel.t() | nil, Channel.t() | nil, map(), map()) :: Message.t()
  defp build_message(user, user_target, user_channel, channel, channel_map, query) do
    if whox?(query) do
      build_whox_message(user, user_target, user_channel, channel, channel_map, query)
    else
      build_standard_message(user, user_target, user_channel, channel, channel_map)
    end
  end

  @spec build_standard_message(User.t(), User.t(), UserChannel.t() | nil, Channel.t() | nil, map()) :: Message.t()
  defp build_standard_message(user, user_target, user_channel, channel, channel_map) do
    %Message{
      command: :rpl_whoreply,
      params: [
        user_reply(user),
        resolve_channel_name(user_channel, channel, channel_map),
        user_target.ident,
        display_hostname(user_target, user),
        Application.get_env(:elixircd, :server)[:hostname],
        user_target.nick,
        user_statuses(user, user_target, user_channel)
      ],
      trailing: "0 #{user_target.realname}"
    }
  end

  @spec build_whox_message(User.t(), User.t(), UserChannel.t() | nil, Channel.t() | nil, map(), map()) :: Message.t()
  defp build_whox_message(user, user_target, user_channel, channel, channel_map, query) do
    context = %{
      requesting_user: user,
      user_target: user_target,
      user_channel: user_channel,
      channel: channel,
      channel_map: channel_map,
      query: query
    }

    {params, trailing} =
      @whox_field_order
      |> Enum.reduce({[user_reply(user)], nil}, fn field, {params_acc, trailing_acc} ->
        if field in query.fields do
          append_whox_field(field, params_acc, trailing_acc, context)
        else
          {params_acc, trailing_acc}
        end
      end)

    %Message{
      command: :rpl_whospcrpl,
      params: params,
      trailing: trailing
    }
  end

  @spec append_whox_field(String.t(), [String.t()], String.t() | nil, map()) :: {[String.t()], String.t() | nil}
  defp append_whox_field("r", params_acc, _trailing_acc, %{user_target: user_target}) do
    {params_acc, user_target.realname}
  end

  defp append_whox_field(field, params_acc, trailing_acc, context) do
    value = whox_field_value(field, context)
    {params_acc ++ [value], trailing_acc}
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

  @spec whox_field_value(String.t(), map()) :: String.t()
  defp whox_field_value("t", %{query: query}), do: query.token

  defp whox_field_value("c", %{user_channel: user_channel, channel: channel, channel_map: channel_map}) do
    resolve_channel_name(user_channel, channel, channel_map)
  end

  defp whox_field_value("u", %{user_target: user_target}), do: user_target.ident

  defp whox_field_value("i", %{requesting_user: requesting_user, user_target: user_target}) do
    whox_ip_address(requesting_user, user_target)
  end

  defp whox_field_value("h", %{requesting_user: requesting_user, user_target: user_target}) do
    display_hostname(user_target, requesting_user)
  end

  defp whox_field_value("s", _context), do: Application.get_env(:elixircd, :server)[:hostname]

  defp whox_field_value("n", %{user_target: user_target}), do: user_target.nick

  defp whox_field_value("f", %{requesting_user: requesting_user, user_target: user_target, user_channel: user_channel}) do
    user_statuses(requesting_user, user_target, user_channel)
  end

  defp whox_field_value("d", _context), do: "0"

  defp whox_field_value("l", %{user_target: user_target}) do
    idle_seconds(user_target)
  end

  defp whox_field_value("a", %{user_target: user_target}) do
    user_target.identified_as || "0"
  end

  defp whox_field_value("o", %{user_channel: user_channel}) do
    whox_op_level(user_channel)
  end

  @spec whox_ip_address(User.t(), User.t()) :: String.t()
  defp whox_ip_address(requesting_user, user_target) do
    if irc_operator?(requesting_user) do
      format_ip_address(user_target.ip_address)
    else
      "255.255.255.255"
    end
  end

  @spec idle_seconds(User.t()) :: String.t()
  defp idle_seconds(user_target) do
    now = :erlang.system_time(:second)
    idle = max(now - user_target.last_activity, 0)
    Integer.to_string(idle)
  end

  @spec whox_op_level(UserChannel.t() | nil) :: String.t()
  defp whox_op_level(%UserChannel{modes: modes}) do
    cond do
      "o" in modes -> "2"
      "v" in modes -> "1"
      true -> "0"
    end
  end

  defp whox_op_level(nil), do: "0"

  @spec user_statuses(User.t(), User.t(), UserChannel.t() | nil) :: String.t()
  defp user_statuses(requesting_user, user_target, user_channel) do
    prefixes = channel_operator_symbol(user_channel) <> channel_voice_symbol(user_channel)
    prefixes = if "multi-prefix" in requesting_user.capabilities, do: prefixes, else: String.slice(prefixes, 0, 1)

    user_away_status(user_target) <> irc_operator_symbol(user_target) <> prefixes
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

  @spec parse_query([String.t()]) :: map()
  defp parse_query(filters) do
    whox_enabled? = Keyword.get(Application.get_env(:elixircd, :whox, []), :enabled, false)

    {pre_whox_filters, whox_param, post_whox_filters} =
      if whox_enabled? do
        split_whox_param(filters)
      else
        {filters, nil, []}
      end

    {inline_filters, fields, token} = parse_whox_fields(whox_param)

    %{
      operator_only: filter_operators?(pre_whox_filters ++ inline_filters ++ post_whox_filters),
      fields: fields,
      token: token
    }
  end

  @spec split_whox_param([String.t()]) :: {[String.t()], String.t() | nil, [String.t()]}
  defp split_whox_param(filters) do
    case Enum.split_while(filters, &(not String.contains?(&1, "%"))) do
      {before, []} -> {before, nil, []}
      {before, [whox_param | rest]} -> {before, whox_param, rest}
    end
  end

  @spec parse_whox_fields(String.t() | nil) :: {[String.t()], [String.t()], String.t() | nil}
  defp parse_whox_fields(nil), do: {[], [], nil}

  defp parse_whox_fields(param) do
    [inline_filters, field_spec] = String.split(param, "%", parts: 2)
    {fields, token} = parse_whox_field_spec(field_spec)
    {split_filter_chars(inline_filters), fields, token}
  end

  @spec parse_whox_field_spec(String.t()) :: {[String.t()], String.t() | nil}
  defp parse_whox_field_spec(field_spec) do
    {fields_part, token} =
      case String.split(field_spec, ",", parts: 2) do
        [fields] -> {fields, nil}
        [fields, token] -> {fields, blank_to_nil(token)}
      end

    fields =
      fields_part
      |> String.graphemes()
      |> Enum.filter(&(&1 in @whox_field_order))
      |> Enum.uniq()
      |> maybe_drop_token_field(token)

    {fields, token}
  end

  @spec maybe_drop_token_field([String.t()], String.t() | nil) :: [String.t()]
  defp maybe_drop_token_field(fields, nil), do: List.delete(fields, "t")
  defp maybe_drop_token_field(fields, _token), do: fields

  @spec blank_to_nil(String.t()) :: String.t() | nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @spec split_filter_chars(String.t()) :: [String.t()]
  defp split_filter_chars(""), do: []
  defp split_filter_chars(filters), do: String.graphemes(filters)

  @spec filter_operators?([String.t()]) :: boolean()
  defp filter_operators?(filters) do
    Enum.any?(filters, fn filter ->
      filter
      |> String.downcase()
      |> String.contains?("o")
    end)
  end

  @spec whox?(map()) :: boolean()
  defp whox?(query), do: query.fields != []
end
