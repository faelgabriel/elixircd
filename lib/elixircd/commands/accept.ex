defmodule ElixIRCd.Commands.Accept do
  @moduledoc """
  This module defines the ACCEPT command.

  The ACCEPT command manages a user's accept list for the +g user mode.
  Users with +g set only receive private messages and notices from users
  on their accept list.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserAcceptRemotes
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.RemoteUser
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserAccept

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "ACCEPT"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "ACCEPT", params: []}) do
    display_accept_list(user)
  end

  def handle(user, %{command: "ACCEPT", params: ["*"]}) do
    display_accept_list(user)
  end

  def handle(user, %{command: "ACCEPT", params: [nick_list | _]}) do
    nicks = String.split(nick_list, ",")

    {add_nicks, remove_nicks} =
      Enum.reduce(nicks, {[], []}, fn nick, {adds, removes} ->
        case String.first(nick) do
          "-" ->
            clean_nick = String.slice(nick, 1, String.length(nick) - 1)
            {adds, [clean_nick | removes]}

          _ ->
            {[nick | adds], removes}
        end
      end)

    handle_batch_add_nicks(user, add_nicks)
    handle_batch_remove_nicks(user, remove_nicks)
  end

  @spec handle_batch_add_nicks(User.t(), [String.t()]) :: :ok
  defp handle_batch_add_nicks(_user, []), do: :ok

  defp handle_batch_add_nicks(user, nicks) do
    users_list = Users.get_by_nicks(nicks)
    users_by_nick = Enum.into(users_list, %{}, fn user -> {user.nick, user} end)

    current_accepts = UserAccepts.get_by_user_pid(user.pid)
    current_accepted_pids = MapSet.new(current_accepts, & &1.accepted_user_pid)

    Enum.each(nicks, fn nick ->
      handle_add_single_nick(user, nick, users_by_nick, current_accepted_pids)
    end)

    :ok
  end

  @spec handle_add_single_nick(User.t(), String.t(), %{String.t() => User.t()}, MapSet.t()) :: :ok
  defp handle_add_single_nick(user, nick, users_by_nick, current_accepted_pids) do
    case Map.get(users_by_nick, nick) do
      nil ->
        add_remote_nick(user, nick)

      target_user ->
        if MapSet.member?(current_accepted_pids, target_user.pid) do
          send_already_accepted_error(user, nick)
        else
          UserAccepts.create(%{user_pid: user.pid, accepted_user_pid: target_user.pid})
          send_accepted_confirmation(user, nick)
        end
    end
  end

  @spec handle_batch_remove_nicks(User.t(), [String.t()]) :: :ok
  defp handle_batch_remove_nicks(_user, []), do: :ok

  defp handle_batch_remove_nicks(user, nicks) do
    users_list = Users.get_by_nicks(nicks)
    users_by_nick = Enum.into(users_list, %{}, fn user -> {user.nick, user} end)

    current_accepts = UserAccepts.get_by_user_pid(user.pid)
    current_accepted_pids = MapSet.new(current_accepts, & &1.accepted_user_pid)

    Enum.each(nicks, fn nick ->
      handle_remove_single_nick(user, nick, users_by_nick, current_accepted_pids)
    end)

    :ok
  end

  @spec handle_remove_single_nick(User.t(), String.t(), %{String.t() => User.t()}, MapSet.t()) :: :ok
  defp handle_remove_single_nick(user, nick, users_by_nick, current_accepted_pids) do
    case Map.get(users_by_nick, nick) do
      nil ->
        remove_remote_nick(user, nick)

      target_user ->
        if MapSet.member?(current_accepted_pids, target_user.pid) do
          UserAccepts.delete(user.pid, target_user.pid)
          send_removed_confirmation(user, nick)
        else
          send_not_accepted_error(user, nick)
        end
    end
  end

  defp add_remote_nick(user, nick) do
    case Directory.lookup_by_nick(nick) do
      {:ok, %RemoteUser{origin: origin, uid: uid}} ->
        identity = {origin, uid}

        if UserAcceptRemotes.get_by_user_pid_and_identity(user.pid, identity) do
          send_already_accepted_error(user, nick)
        else
          UserAcceptRemotes.create(user.pid, identity)
          send_accepted_confirmation(user, nick)
        end

      :error ->
        send_no_such_nick_error(user, nick)

      :unavailable ->
        send_missing_remote_nick_error(user, nick)
    end
  end

  defp remove_remote_nick(user, nick) do
    case Directory.lookup_by_nick(nick) do
      {:ok, %RemoteUser{origin: origin, uid: uid}} ->
        identity = {origin, uid}

        if UserAcceptRemotes.get_by_user_pid_and_identity(user.pid, identity) do
          UserAcceptRemotes.delete(user.pid, identity)
          send_removed_confirmation(user, nick)
        else
          send_not_accepted_error(user, nick)
        end

      :error ->
        send_no_such_nick_error(user, nick)

      :unavailable ->
        send_missing_remote_nick_error(user, nick)
    end
  end

  defp send_missing_remote_nick_error(user, nick) do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      %Message{
        command: :err_unavailresource,
        params: [user.nick, nick],
        trailing: "Network user directory is unavailable"
      }
      |> Dispatcher.broadcast(:server, user)
    else
      send_no_such_nick_error(user, nick)
    end
  end

  @spec send_no_such_nick_error(User.t(), String.t()) :: :ok
  defp send_no_such_nick_error(user, nick) do
    %Message{command: :err_nosuchnick, params: [user.nick, nick], trailing: "No such nick"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_already_accepted_error(User.t(), String.t()) :: :ok
  defp send_already_accepted_error(user, nick) do
    %Message{command: :err_acceptexist, params: [user.nick, nick], trailing: "User is already on your accept list"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_accepted_confirmation(User.t(), String.t()) :: :ok
  defp send_accepted_confirmation(user, nick) do
    %Message{command: :rpl_accepted, params: [user.nick, nick], trailing: "#{nick} has been added to your accept list"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_not_accepted_error(User.t(), String.t()) :: :ok
  defp send_not_accepted_error(user, nick) do
    %Message{command: :err_acceptnot, params: [user.nick, nick], trailing: "User is not on your accept list"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_removed_confirmation(User.t(), String.t()) :: :ok
  defp send_removed_confirmation(user, nick) do
    %Message{
      command: :rpl_acceptremoved,
      params: [user.nick, nick],
      trailing: "#{nick} has been removed from your accept list"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec display_accept_list(User.t()) :: :ok
  defp display_accept_list(user) do
    accept_list = UserAccepts.get_by_user_pid(user.pid)
    remote_accepts = UserAcceptRemotes.get_by_user_pid(user.pid)

    if accept_list == [] and remote_accepts == [] do
      send_accept_list_end(user)
    else
      send_accept_list_entries(user, accept_list)
      send_remote_accept_list_entries(user, remote_accepts)
      send_accept_list_end(user)
    end
  end

  defp send_remote_accept_list_entries(user, accepts) do
    Enum.each(accepts, fn accept ->
      {origin, uid} = accept.accepted_identity

      case Directory.get_by_identity(origin, uid) do
        {:ok, %RemoteUser{user: %{"nick" => nick}}} ->
          %Message{command: :rpl_acceptlist, params: [user.nick, nick], trailing: ""}
          |> Dispatcher.broadcast(:server, user)

        :error ->
          :ok
      end
    end)
  end

  @spec send_accept_list_entries(User.t(), [UserAccept.t()]) :: :ok
  defp send_accept_list_entries(user, accepts) do
    accepted_pids = Enum.map(accepts, & &1.accepted_user_pid)
    accepted_users = Users.get_by_pids(accepted_pids)
    users_by_pid = Enum.into(accepted_users, %{}, fn user -> {user.pid, user} end)

    Enum.each(accepts, fn accept ->
      case Map.get(users_by_pid, accept.accepted_user_pid) do
        nil ->
          :ok

        accepted_user ->
          %Message{command: :rpl_acceptlist, params: [user.nick, accepted_user.nick], trailing: ""}
          |> Dispatcher.broadcast(:server, user)
      end
    end)
  end

  @spec send_accept_list_end(User.t()) :: :ok
  defp send_accept_list_end(user) do
    %Message{command: :rpl_acceptlistend, params: [user.nick], trailing: "End of accept list"}
    |> Dispatcher.broadcast(:server, user)
  end
end
