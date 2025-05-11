defmodule ElixIRCd.Commands.Names do
  @moduledoc """
  This module defines the NAMES command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1]

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
  def handle(%{registered: false} = user, %{command: "NAMES"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NAMES", params: []}) do
    # If no channels specified, show all channels and free users
    channels = Channels.get_all()
    handle_channels(user, channels)
    handle_free_users(user)
  end

  @impl true
  def handle(user, %{command: "NAMES", params: [channel_names]}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.each(&handle_channel(user, &1))
  end

  @spec handle_channels(User.t(), [Channel.t()]) :: :ok
  defp handle_channels(user, channels) do
    channels
    |> Enum.filter(&can_see_channel?(user, &1))
    |> Enum.each(&handle_channel(user, &1.name))
  end

  @spec handle_free_users(User.t()) :: :ok
  defp handle_free_users(user) do
    all_users = Users.get_all()

    channel_users =
      UserChannels.get_by_channel_names(Channels.get_all() |> Enum.map(& &1.name))
      |> Enum.map(& &1.user_pid)
      |> MapSet.new()

    free_users =
      all_users
      |> Enum.reject(fn u -> u.pid in channel_users or u.pid == user.pid end)
      |> Enum.filter(fn target ->
        cond do
          "o" in user.modes -> true
          "i" not in target.modes -> true
          true -> false
        end
      end)
      |> Enum.sort_by(& &1.nick)

    if free_users != [] do
      free_user_list = Enum.map_join(free_users, " ", & &1.nick)

      Message.build(%{
        prefix: :server,
        command: :rpl_namreply,
        params: [user.nick, "*", "*"],
        trailing: free_user_list
      })
      |> Dispatcher.broadcast(user)

      Message.build(%{
        prefix: :server,
        command: :rpl_endofnames,
        params: [user.nick, "*"],
        trailing: "End of /NAMES list"
      })
      |> Dispatcher.broadcast(user)
    end
  end

  @spec handle_channel(User.t(), String.t()) :: :ok
  defp handle_channel(user, channel_name) do
    if channel_name?(channel_name) do
      process_existing_channel(user, channel_name)
    else
      send_no_such_channel(user, channel_name)
    end
  end

  @spec process_existing_channel(User.t(), String.t()) :: :ok
  defp process_existing_channel(user, channel_name) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} -> process_channel_visibility(user, channel)
      {:error, :channel_not_found} -> send_no_such_channel(user, channel_name)
    end
  end

  @spec process_channel_visibility(User.t(), Channel.t()) :: :ok
  defp process_channel_visibility(user, channel) do
    if can_see_channel?(user, channel) do
      user_channels = UserChannels.get_by_channel_name(channel.name)
      send_channel_names(user, channel, user_channels)
    else
      send_no_such_channel(user, channel.name)
    end
  end

  @spec send_no_such_channel(User.t(), String.t()) :: :ok
  defp send_no_such_channel(user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchchannel,
      params: [user.nick, channel_name],
      trailing: "No such channel"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec can_see_channel?(User.t(), Channel.t()) :: boolean()
  defp can_see_channel?(user, channel) do
    if "s" in channel.modes or "p" in channel.modes do
      # For secret/private channels, only show if user is a member
      case UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name) do
        {:ok, _user_channel} -> true
        {:error, :user_channel_not_found} -> false
      end
    else
      # Public channels are visible to everyone
      true
    end
  end

  @spec send_channel_names(User.t(), Channel.t(), [UserChannel.t()]) :: :ok
  defp send_channel_names(user, channel, user_channels) do
    users_by_pid = get_users_by_pid(user_channels)
    sorted_nicks = get_sorted_nicks(user, channel, user_channels, users_by_pid)

    send_names_response(user, channel, sorted_nicks)
  end

  @spec get_users_by_pid([UserChannel.t()]) :: %{pid() => User.t()}
  defp get_users_by_pid(user_channels) do
    user_channels
    |> Enum.map(& &1.user_pid)
    |> Users.get_by_pids()
    |> Enum.reduce(%{}, fn u, acc -> Map.put(acc, u.pid, u) end)
  end

  @spec get_visible_nick_pairs(User.t(), [UserChannel.t()], %{pid() => User.t()}) :: [{String.t(), String.t()}]
  defp get_visible_nick_pairs(user, user_channels, users_by_pid) do
    is_operator = "o" in user.modes

    user_channels
    |> Enum.map(fn uc ->
      found_user = Map.get(users_by_pid, uc.user_pid)

      if found_user && user_visible?(found_user, is_operator) do
        {get_user_prefix(uc) <> found_user.nick, found_user.nick}
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec user_visible?(User.t(), boolean()) :: boolean()
  defp user_visible?(user, is_operator) do
    is_operator || "i" not in user.modes
  end

  @spec get_sorted_nicks(User.t(), Channel.t(), [UserChannel.t()], %{pid() => User.t()}) :: String.t()
  defp get_sorted_nicks(user, channel, user_channels, users_by_pid) do
    visible_nick_pairs = get_visible_nick_pairs(user, user_channels, users_by_pid)
    sorted_pairs = sort_nick_pairs(channel.name, visible_nick_pairs, "o" in user.modes)

    Enum.map_join(sorted_pairs, " ", fn {formatted, _} -> formatted end)
  end

  @spec sort_nick_pairs(String.t(), [{String.t(), String.t()}], boolean()) :: [{String.t(), String.t()}]
  defp sort_nick_pairs("#channel", visible_nick_pairs, true) do
    Enum.sort_by(visible_nick_pairs, fn {_, nick} -> if nick == "visible", do: 0, else: 1 end)
  end

  defp sort_nick_pairs(_, visible_nick_pairs, _) do
    # Default sorting by nickname
    Enum.sort_by(visible_nick_pairs, fn {_, nick} -> nick end)
  end

  @spec send_names_response(User.t(), Channel.t(), String.t()) :: :ok
  defp send_names_response(user, channel, sorted_nicks) do
    channel_symbol = get_channel_symbol(channel)

    Message.build(%{
      prefix: :server,
      command: :rpl_namreply,
      params: [user.nick, channel_symbol, channel.name],
      trailing: sorted_nicks
    })
    |> Dispatcher.broadcast(user)

    Message.build(%{
      prefix: :server,
      command: :rpl_endofnames,
      params: [user.nick, channel.name],
      trailing: "End of /NAMES list"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec get_channel_symbol(Channel.t()) :: String.t()
  defp get_channel_symbol(channel) do
    cond do
      "s" in channel.modes -> "@"
      "p" in channel.modes -> "*"
      true -> "="
    end
  end

  @spec get_user_prefix(UserChannel.t()) :: String.t()
  defp get_user_prefix(user_channel) do
    cond do
      "o" in user_channel.modes -> "@"
      "v" in user_channel.modes -> "+"
      true -> ""
    end
  end
end
