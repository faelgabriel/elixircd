defmodule ElixIRCd.Commands.Names do
  @moduledoc """
  This module defines the NAMES command.

  NAMES lists the nicknames of users in specified channels or all visible channels.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, chunk_message_words: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Targets

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "NAMES"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "NAMES", params: []}) do
    handle_all_names(user)
  end

  def handle(user, %{command: "NAMES", params: [channel_names | _rest]}) do
    targets = "NAMES" |> Targets.split(channel_names) |> Enum.map(&String.trim/1)
    Enum.each(targets, &handle_single_channel_names(user, &1))
    send_end_of_names(user, Enum.join(targets, ","))
  end

  @spec handle_all_names(User.t()) :: :ok
  defp handle_all_names(user) do
    case network_runtime() do
      {:ok, runtime} -> handle_all_network_names(user, runtime)
      :unavailable -> handle_all_local_names(user)
    end

    send_end_of_names(user, "*")
  end

  @spec handle_all_local_names(User.t()) :: :ok
  defp handle_all_local_names(user) do
    Channels.get_all()
    |> Enum.sort_by(& &1.name_key)
    |> Enum.each(&handle_channel_names_silent(user, &1))

    handle_free_users(user)
  end

  @spec handle_single_channel_names(User.t(), String.t()) :: :ok
  defp handle_single_channel_names(user, channel_name) do
    case network_channel(channel_name) do
      {:ok, runtime, channel, runtime_channel} ->
        handle_network_channel_names(user, runtime, channel, runtime_channel)

      :unavailable ->
        case Channels.get_by_name(channel_name) do
          {:ok, channel} -> handle_existing_channel(user, channel)
          {:error, :channel_not_found} -> :ok
        end
    end
  end

  @spec network_runtime() :: {:ok, map()} | :unavailable
  defp network_runtime do
    case Process.whereis(Manager) do
      nil ->
        :unavailable

      manager ->
        case View.runtime(manager) do
          {:ok, runtime} -> {:ok, runtime}
          {:error, _reason} -> :unavailable
        end
    end
  end

  @spec network_channel(String.t()) :: {:ok, map(), Channel.t(), map()} | :unavailable
  defp network_channel(channel_name) do
    with {:ok, runtime} <- network_runtime(),
         {:ok, channel, runtime_channel} <- View.channel(runtime, channel_name) do
      {:ok, runtime, channel, runtime_channel}
    else
      :unavailable -> :unavailable
      {:error, :channel_not_found} -> :unavailable
    end
  end

  @spec handle_all_network_names(User.t(), map()) :: :ok
  defp handle_all_network_names(user, runtime) do
    runtime.channels
    |> Map.values()
    |> Enum.reject(&String.starts_with?(&1.ref["name"], "&"))
    |> Enum.sort_by(&CaseMapping.normalize(&1.ref["name"]))
    |> Enum.each(fn runtime_channel ->
      case View.channel(runtime, runtime_channel.ref["name"]) do
        {:ok, channel, current} -> handle_network_channel_names(user, runtime, channel, current)
        {:error, _} -> :ok
      end
    end)

    handle_network_free_users(user, runtime)
  end

  @spec handle_network_channel_names(User.t(), map(), Channel.t(), map()) :: :ok
  defp handle_network_channel_names(user, runtime, channel, runtime_channel) do
    if network_channel_visible_to_user?(runtime, channel, user) do
      send_network_names_reply(user, runtime, channel, runtime_channel)
    end

    :ok
  end

  @spec network_channel_visible_to_user?(map(), Channel.t(), User.t()) :: boolean()
  defp network_channel_visible_to_user?(runtime, channel, user) do
    is_member = match?({:ok, _}, View.membership(runtime, user.uid, channel.name))
    is_member or (:s not in channel.modes and :p not in channel.modes)
  end

  @spec send_network_names_reply(User.t(), map(), Channel.t(), map()) :: :ok
  defp send_network_names_reply(user, runtime, channel, runtime_channel) do
    visible_nicks =
      runtime
      |> View.channel_members_with_services(runtime_channel)
      |> get_visible_network_nick_pairs(user)
      |> get_sorted_nicks()

    messages =
      if Enum.empty?(visible_nicks) do
        []
      else
        params =
          if Application.fetch_env!(:elixircd, :compatibility)[:rfc1459_names],
            do: [user.nick, channel.name],
            else: [user.nick, get_channel_status(channel), channel.name]

        %Message{prefix: Dispatcher.server_prefix(), command: :rpl_namreply, params: params}
        |> chunk_message_words(visible_nicks)
      end

    Dispatcher.broadcast(messages, :server, user)
  end

  @spec get_visible_network_nick_pairs([{String.t(), User.t(), UserChannel.t()}], User.t()) ::
          [{String.t(), String.t(), String.t()}]
  defp get_visible_network_nick_pairs(members, user) do
    is_operator = :o in user.modes
    is_member = Enum.any?(members, fn {uid, _target, _record} -> uid == user.uid end)
    use_extended_names = "userhost-in-names" in user.capabilities
    use_multi_prefix = "multi-prefix" in user.capabilities

    Enum.map(members, fn {_uid, found_user, user_channel} ->
      if user_visible?(found_user, user, is_operator, is_member) do
        prefix = get_user_prefix(user_channel, use_multi_prefix)
        formatted_user = prefix <> format_user_display(found_user, use_extended_names)
        {formatted_user, prefix <> found_user.nick, found_user.nick}
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec handle_network_free_users(User.t(), map()) :: :ok
  defp handle_network_free_users(user, runtime) do
    free_users =
      runtime.users
      |> Map.keys()
      |> Enum.flat_map(fn uid ->
        case View.user(runtime, uid) do
          {:ok, target} -> [{uid, target}]
          _ -> []
        end
      end)
      |> Enum.reject(fn {uid, _target} -> uid == user.uid or has_network_membership?(runtime, uid) end)
      |> Enum.filter(fn {_uid, target} -> :o in user.modes or :i not in target.modes end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort_by(&CaseMapping.normalize(&1.nick || ""))

    if free_users != [] do
      use_extended_names = "userhost-in-names" in user.capabilities

      free_user_list =
        Enum.map(free_users, fn free_user ->
          {format_user_display(free_user, use_extended_names), free_user.nick}
        end)

      params =
        if Application.fetch_env!(:elixircd, :compatibility)[:rfc1459_names],
          do: [user.nick, "*"],
          else: [user.nick, "*", "*"]

      %Message{prefix: Dispatcher.server_prefix(), command: :rpl_namreply, params: params}
      |> chunk_message_words(free_user_list)
      |> Dispatcher.broadcast(:server, user)
    end

    :ok
  end

  @spec has_network_membership?(map(), String.t()) :: boolean()
  defp has_network_membership?(runtime, uid) do
    case runtime.memberships[uid] do
      %{entries: entries} when is_list(entries) -> entries != []
      _ -> false
    end
  end

  defp handle_existing_channel(user, channel) do
    if channel_visible_to_user?(channel, user), do: send_names_reply(user, channel)
  end

  @spec send_end_of_names(User.t(), String.t()) :: :ok
  defp send_end_of_names(user, channel_name) do
    %Message{command: :rpl_endofnames, params: [user.nick, channel_name], trailing: "End of /NAMES list"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_channel_names_silent(User.t(), Channel.t()) :: :ok
  defp handle_channel_names_silent(user, channel) do
    if channel_visible_to_user?(channel, user) do
      send_names_reply(user, channel)
    end

    :ok
  end

  @spec channel_visible_to_user?(Channel.t(), User.t()) :: boolean()
  defp channel_visible_to_user?(channel, user) do
    is_member =
      case UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name) do
        {:ok, _user_channel} -> true
        {:error, :user_channel_not_found} -> false
      end

    is_secret = :s in channel.modes
    is_private = :p in channel.modes

    cond do
      is_member -> true
      is_secret -> false
      is_private -> false
      true -> true
    end
  end

  @spec send_names_reply(User.t(), Channel.t()) :: :ok
  defp send_names_reply(user, channel) do
    user_channels = UserChannels.get_by_channel_name(channel.name)
    users_by_pid = get_users_by_pid(user_channels)

    visible_nicks =
      get_visible_nick_pairs(user, user_channels, users_by_pid)
      |> get_sorted_nicks()

    # 366 always terminates the reply for a visible channel; 353 is only sent with content.
    messages =
      if Enum.empty?(visible_nicks) do
        []
      else
        params =
          if Application.fetch_env!(:elixircd, :compatibility)[:rfc1459_names],
            do: [user.nick, channel.name],
            else: [user.nick, get_channel_status(channel), channel.name]

        names_message = %Message{
          prefix: Dispatcher.server_prefix(),
          command: :rpl_namreply,
          params: params
        }

        chunk_message_words(names_message, visible_nicks)
      end

    messages
    |> Dispatcher.broadcast(:server, user)
  end

  @spec get_channel_status(Channel.t()) :: String.t()
  defp get_channel_status(channel) do
    cond do
      :s in channel.modes -> "@"
      :p in channel.modes -> "*"
      true -> "="
    end
  end

  @spec get_users_by_pid([UserChannel.t()]) :: %{pid() => User.t()}
  defp get_users_by_pid(user_channels) do
    Enum.map(user_channels, & &1.user_pid)
    |> Users.get_by_pids()
    |> Map.new(fn user -> {user.pid, user} end)
  end

  @spec get_visible_nick_pairs(User.t(), [UserChannel.t()], %{pid() => User.t()}) ::
          [{String.t(), String.t(), String.t()}]
  defp get_visible_nick_pairs(user, user_channels, users_by_pid) do
    is_operator = :o in user.modes
    is_member = Enum.any?(user_channels, &(&1.uid == user.uid))
    use_extended_names = "userhost-in-names" in user.capabilities
    use_multi_prefix = "multi-prefix" in user.capabilities

    user_channels
    |> Enum.map(fn uc ->
      found_user = Map.get(users_by_pid, uc.user_pid)

      if found_user && user_visible?(found_user, user, is_operator, is_member) do
        prefix = get_user_prefix(uc, use_multi_prefix)
        formatted_user = prefix <> format_user_display(found_user, use_extended_names)
        {formatted_user, prefix <> found_user.nick, found_user.nick}
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec user_visible?(User.t(), User.t(), boolean(), boolean()) :: boolean()
  defp user_visible?(target_user, requesting_user, is_operator, is_member) do
    # Members see each other; +i hides users from outsiders. +H only hides oper status.
    cond do
      User.same_identity?(target_user, requesting_user) -> true
      is_operator -> true
      is_member -> true
      true -> :i not in target_user.modes
    end
  end

  @spec get_sorted_nicks([{String.t(), String.t(), String.t()}]) :: [{String.t(), String.t()}]
  defp get_sorted_nicks(nick_pairs) do
    nick_pairs
    |> Enum.sort_by(fn {_formatted, _fallback, nick} -> String.downcase(nick) end)
    |> Enum.map(fn {formatted, fallback, _nick} -> {formatted, fallback} end)
  end

  @spec handle_free_users(User.t()) :: :ok
  defp handle_free_users(user) do
    all_users = Users.get_all()

    channel_users =
      UserChannels.get_by_channel_names(Channels.get_all() |> Enum.map(& &1.name))
      |> Enum.map(& &1.uid)
      |> MapSet.new()

    free_users =
      all_users
      |> Enum.filter(& &1.registered)
      |> Enum.reject(fn u -> u.uid in channel_users or User.same_identity?(u, user) end)
      |> Enum.filter(fn target ->
        cond do
          :o in user.modes -> true
          :i not in target.modes -> true
          true -> false
        end
      end)
      |> Enum.sort_by(& &1.nick)

    if free_users != [] do
      use_extended_names = "userhost-in-names" in user.capabilities

      free_user_list =
        Enum.map(free_users, fn free_user ->
          {format_user_display(free_user, use_extended_names), free_user.nick}
        end)

      params =
        if Application.fetch_env!(:elixircd, :compatibility)[:rfc1459_names],
          do: [user.nick, "*"],
          else: [user.nick, "*", "*"]

      %Message{prefix: Dispatcher.server_prefix(), command: :rpl_namreply, params: params}
      |> chunk_message_words(free_user_list)
      |> Dispatcher.broadcast(:server, user)
    end

    :ok
  end

  @spec get_user_prefix(UserChannel.t(), boolean()) :: String.t()
  defp get_user_prefix(user_channel, true = _use_multi_prefix) do
    []
    |> maybe_add_user_prefix(:o in user_channel.modes, "@")
    |> maybe_add_user_prefix(:v in user_channel.modes, "+")
    |> Enum.reverse()
    |> Enum.join("")
  end

  defp get_user_prefix(user_channel, false = _use_multi_prefix) do
    cond do
      :o in user_channel.modes -> "@"
      :v in user_channel.modes -> "+"
      true -> ""
    end
  end

  @spec maybe_add_user_prefix([String.t()], boolean(), String.t()) :: [String.t()]
  defp maybe_add_user_prefix(acc, true, prefix), do: [prefix | acc]
  defp maybe_add_user_prefix(acc, false, _prefix), do: acc

  @spec format_user_display(User.t(), boolean()) :: String.t()
  defp format_user_display(user, true = _use_extended_names), do: user_mask(user)
  defp format_user_display(user, false = _use_extended_names), do: user.nick
end
