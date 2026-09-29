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
  alias ElixIRCd.ServerLink.ChannelDirectory
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
    views = ChannelDirectory.all()
    links_enabled? = Application.fetch_env!(:elixircd, :server_links)[:enabled]

    if links_enabled? and views == :unavailable do
      send_end_of_names(user, "*")
    else
      send_all_visible_names(user, views)
    end
  end

  defp send_all_visible_names(user, views) do
    local_channels = Channels.get_all()

    local_channels
    |> Enum.sort_by(& &1.name_key)
    |> Enum.each(&handle_channel_names_silent(user, &1))

    local_keys = MapSet.new(local_channels, & &1.name_key)

    case views do
      views when is_list(views) ->
        views
        |> Enum.reject(&MapSet.member?(local_keys, CaseMapping.normalize(&1.channel["name"])))
        |> Enum.sort_by(&CaseMapping.normalize(&1.channel["name"]))
        |> Enum.each(&handle_remote_channel_names_silent(user, &1))

      :unavailable ->
        :ok
    end

    handle_free_users(user)
    send_end_of_names(user, "*")
  end

  @spec handle_single_channel_names(User.t(), String.t()) :: :ok
  defp handle_single_channel_names(user, channel_name) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} -> handle_existing_channel(user, channel)
      {:error, :channel_not_found} -> handle_remote_channel_names(user, channel_name)
    end
  end

  defp handle_existing_channel(user, channel) do
    view = ChannelDirectory.get(channel.name)
    links_enabled? = Application.fetch_env!(:elixircd, :server_links)[:enabled]

    if not links_enabled? or match?({:ok, _}, view) do
      modes = channel_modes(channel, view)

      if channel_visible_to_user?(channel.name, modes, user) do
        send_names_reply(
          user,
          channel.name,
          modes,
          UserChannels.get_by_channel_name(channel.name),
          remote_members(view)
        )
      end
    end
  end

  defp handle_remote_channel_names(user, channel_name) do
    case ChannelDirectory.get(channel_name) do
      {:ok, view} -> handle_remote_channel_names_silent(user, view)
      _ -> :ok
    end
  end

  defp handle_remote_channel_names_silent(user, view) do
    name = view.channel["name"]
    modes = channel_modes(nil, {:ok, view})

    if channel_visible_to_user?(name, modes, user),
      do: send_names_reply(user, name, modes, [], view.remote_members)
  end

  @spec send_end_of_names(User.t(), String.t()) :: :ok
  defp send_end_of_names(user, channel_name) do
    %Message{command: :rpl_endofnames, params: [user.nick, channel_name], trailing: "End of /NAMES list"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_channel_names_silent(User.t(), Channel.t()) :: :ok
  defp handle_channel_names_silent(user, channel) do
    handle_existing_channel(user, channel)
    :ok
  end

  @spec channel_visible_to_user?(String.t(), [String.t()], User.t()) :: boolean()
  defp channel_visible_to_user?(channel_name, modes, user) do
    is_member =
      case UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name) do
        {:ok, _user_channel} -> true
        {:error, :user_channel_not_found} -> false
      end

    is_secret = "s" in modes
    is_private = "p" in modes

    cond do
      is_member -> true
      is_secret -> false
      is_private -> false
      true -> true
    end
  end

  @spec send_names_reply(User.t(), String.t(), [String.t()], [UserChannel.t()], [map()]) :: :ok
  defp send_names_reply(user, channel_name, modes, user_channels, remote_members) do
    users_by_pid = get_users_by_pid(user_channels)

    visible_nicks =
      get_visible_nick_pairs(user, user_channels, users_by_pid)
      |> Kernel.++(get_visible_remote_nick_pairs(user, user_channels, remote_members))
      |> get_sorted_nicks()

    # 366 always terminates the reply for a visible channel; 353 is only sent with content.
    messages =
      if Enum.empty?(visible_nicks) do
        []
      else
        params =
          if Application.fetch_env!(:elixircd, :compatibility)[:rfc1459_names],
            do: [user.nick, channel_name],
            else: [user.nick, get_channel_status(modes), channel_name]

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

  @spec get_channel_status([String.t()]) :: String.t()
  defp get_channel_status(modes) do
    cond do
      "s" in modes -> "@"
      "p" in modes -> "*"
      true -> "="
    end
  end

  defp channel_modes(channel, {:ok, view}) do
    selected = Enum.map(view.channel["modes"], & &1["name"])

    case channel do
      nil -> selected
      _ -> Enum.uniq(selected ++ Enum.filter(channel_modes(channel, :error), &(&1 in ["s", "p"])))
    end
  end

  defp channel_modes(channel, _view) do
    Enum.map(channel.modes, fn
      {mode, _parameter} -> Atom.to_string(mode)
      mode -> Atom.to_string(mode)
    end)
  end

  defp remote_members({:ok, view}), do: view.remote_members
  defp remote_members(_view), do: []

  defp get_visible_remote_nick_pairs(user, local_members, remote_members) do
    is_operator = :o in user.modes
    is_member = Enum.any?(local_members, &(&1.user_pid == user.pid))
    use_extended_names = "userhost-in-names" in user.capabilities
    use_multi_prefix = "multi-prefix" in user.capabilities

    Enum.flat_map(
      remote_members,
      &visible_remote_nick_pair(&1, is_operator or is_member, use_extended_names, use_multi_prefix)
    )
  end

  defp visible_remote_nick_pair(%{effective_modes: modes, user: remote_user}, privileged?, extended?, multi?) do
    if privileged? or "i" not in remote_user["modes"] do
      prefix = remote_prefix(modes, multi?)
      nick = remote_user["nick"]
      display = if extended?, do: remote_mask(remote_user), else: nick
      [{prefix <> display, prefix <> nick, nick}]
    else
      []
    end
  end

  defp remote_prefix(modes, true) do
    if("o" in modes, do: "@", else: "") <> if "v" in modes, do: "+", else: ""
  end

  defp remote_prefix(modes, false) do
    cond do
      "o" in modes -> "@"
      "v" in modes -> "+"
      true -> ""
    end
  end

  defp remote_mask(user) do
    hostname = if "x" in user["modes"], do: user["cloaked_hostname"] || user["hostname"], else: user["hostname"]
    "#{user["nick"]}!#{user["ident"]}@#{hostname}"
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
    is_member = Enum.any?(user_channels, &(&1.user_pid == user.pid))
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
      target_user.pid == requesting_user.pid -> true
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

    channel_users = UserChannels.all_user_pids()

    free_users =
      all_users
      |> Enum.filter(& &1.registered)
      |> Enum.reject(fn u -> u.pid in channel_users or u.pid == user.pid end)
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
