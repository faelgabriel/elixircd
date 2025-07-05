defmodule ElixIRCd.Commands.Names do
  @moduledoc """
  This module defines the NAMES command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, user_mask: 1]

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

  def handle(user, %{command: "NAMES", params: []}) do
    handle_all_names(user)
  end

  def handle(user, %{command: "NAMES", params: [channel_names | _rest]}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.each(&handle_single_channel_names_with_validation(user, &1))
  end

  @spec handle_all_names(User.t()) :: :ok
  defp handle_all_names(user) do
    Channels.get_all()
    |> Enum.each(fn channel -> handle_channel_names_silent(user, channel) end)

    handle_free_users(user)
  end

  @spec handle_single_channel_names_with_validation(User.t(), String.t()) :: :ok
  defp handle_single_channel_names_with_validation(user, channel_name) do
    case channel_name?(channel_name) do
      true ->
        handle_single_channel_names(user, channel_name)

      false ->
        send_no_such_channel_error(user, channel_name)
    end
  end

  @spec handle_single_channel_names(User.t(), String.t()) :: :ok
  defp handle_single_channel_names(user, channel_name) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} ->
        if channel_visible_to_user?(channel, user) do
          send_names_reply(user, channel)
        else
          send_no_such_channel_error(user, channel_name)
        end

      {:error, :channel_not_found} ->
        send_no_such_channel_error(user, channel_name)
    end
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

    is_secret = "s" in channel.modes
    is_private = "p" in channel.modes

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

    unless Enum.empty?(visible_nicks) do
      nicks_string = Enum.join(visible_nicks, " ")

      [
        Message.build(%{
          prefix: :server,
          command: :rpl_namreply,
          params: [user.nick, get_channel_status(channel), channel.name],
          trailing: nicks_string
        }),
        Message.build(%{
          prefix: :server,
          command: :rpl_endofnames,
          params: [user.nick, channel.name],
          trailing: "End of /NAMES list"
        })
      ]
      |> Dispatcher.broadcast(user)
    end
  end

  @spec send_no_such_channel_error(User.t(), String.t()) :: :ok
  defp send_no_such_channel_error(user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchchannel,
      params: [user.nick, channel_name],
      trailing: "No such channel"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec get_channel_status(Channel.t()) :: String.t()
  defp get_channel_status(channel) do
    cond do
      "s" in channel.modes -> "@"
      "p" in channel.modes -> "*"
      true -> "="
    end
  end

  @spec get_users_by_pid([UserChannel.t()]) :: %{pid() => User.t()}
  defp get_users_by_pid(user_channels) do
    Enum.map(user_channels, & &1.user_pid)
    |> Users.get_by_pids()
    |> Map.new(fn user -> {user.pid, user} end)
  end

  @spec get_visible_nick_pairs(User.t(), [UserChannel.t()], %{pid() => User.t()}) :: [{String.t(), String.t()}]
  defp get_visible_nick_pairs(user, user_channels, users_by_pid) do
    is_operator = user.operator_authenticated
    use_extended_names = "UHNAMES" in user.capabilities

    user_channels
    |> Enum.map(fn uc ->
      found_user = Map.get(users_by_pid, uc.user_pid)

      if found_user && user_visible?(found_user, is_operator) do
        prefix = get_user_prefix(uc)
        formatted_user = prefix <> format_user_display(found_user, use_extended_names)
        {formatted_user, found_user.nick}
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec user_visible?(User.t(), boolean()) :: boolean()
  defp user_visible?(user, is_requesting_user_operator) do
    case is_requesting_user_operator do
      true -> true
      false -> "i" not in user.modes and "H" not in user.modes
    end
  end

  @spec get_sorted_nicks([{String.t(), String.t()}]) :: [String.t()]
  defp get_sorted_nicks(nick_pairs) do
    nick_pairs
    |> Enum.sort_by(fn {_formatted, nick} -> String.downcase(nick) end)
    |> Enum.map(fn {formatted, _nick} -> formatted end)
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
          user.operator_authenticated -> true
          "i" not in target.modes and "H" not in target.modes -> true
          true -> false
        end
      end)
      |> Enum.sort_by(& &1.nick)

    if free_users != [] do
      use_extended_names = "UHNAMES" in user.capabilities

      free_user_list =
        Enum.map_join(free_users, " ", &format_user_display(&1, use_extended_names))

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

    :ok
  end

  @spec get_user_prefix(UserChannel.t()) :: String.t()
  defp get_user_prefix(user_channel) do
    cond do
      "o" in user_channel.modes -> "@"
      "v" in user_channel.modes -> "+"
      true -> ""
    end
  end

  @spec format_user_display(User.t(), boolean()) :: String.t()
  defp format_user_display(user, true = _use_extended_names), do: user_mask(user)
  defp format_user_display(user, false = _use_extended_names), do: user.nick
end
