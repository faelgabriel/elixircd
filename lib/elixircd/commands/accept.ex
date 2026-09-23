defmodule ElixIRCd.Commands.Accept do
  @moduledoc """
  This module defines the ACCEPT command.

  The ACCEPT command manages a user's accept list for the +g user mode.
  Users with +g set only receive private messages and notices from users
  on their accept list.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserAccept
  alias ElixIRCd.Utils.CaseMapping

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
    users_by_nick = Enum.into(users_list, %{}, fn target -> {CaseMapping.normalize(target.nick), target} end)

    current_accepts = UserAccepts.get_by_user_pid(user.pid)
    current_accepted_uids = MapSet.new(current_accepts, &accepted_uid/1)

    Enum.each(nicks, fn nick ->
      handle_add_single_nick(user, nick, users_by_nick, current_accepted_uids)
    end)

    :ok
  end

  @spec handle_add_single_nick(User.t(), String.t(), %{String.t() => User.t()}, MapSet.t()) :: :ok
  defp handle_add_single_nick(user, nick, users_by_nick, current_accepted_pids) do
    target_user = Map.get(users_by_nick, CaseMapping.normalize(nick)) || network_user_by_nick(nick)

    case target_user do
      nil ->
        send_no_such_nick_error(user, nick)

      target_user ->
        if MapSet.member?(current_accepted_pids, target_user.uid) or
             UserAccepts.get_by_user_pid_and_accepted_uid(user.pid, target_user.uid) != nil do
          send_already_accepted_error(user, nick)
        else
          UserAccepts.create(%{
            user_pid: user.pid,
            user_uid: user.uid,
            accepted_user_pid: target_user.pid,
            accepted_user_uid: target_user.uid
          })

          send_accepted_confirmation(user, nick)
        end
    end
  end

  @spec handle_batch_remove_nicks(User.t(), [String.t()]) :: :ok
  defp handle_batch_remove_nicks(_user, []), do: :ok

  defp handle_batch_remove_nicks(user, nicks) do
    users_list = Users.get_by_nicks(nicks)
    users_by_nick = Enum.into(users_list, %{}, fn target -> {CaseMapping.normalize(target.nick), target} end)

    current_accepts = UserAccepts.get_by_user_pid(user.pid)
    current_accepted_uids = MapSet.new(current_accepts, &accepted_uid/1)

    Enum.each(nicks, fn nick ->
      handle_remove_single_nick(user, nick, users_by_nick, current_accepted_uids)
    end)

    :ok
  end

  @spec handle_remove_single_nick(User.t(), String.t(), %{String.t() => User.t()}, MapSet.t()) :: :ok
  defp handle_remove_single_nick(user, nick, users_by_nick, current_accepted_pids) do
    target_user = Map.get(users_by_nick, CaseMapping.normalize(nick)) || network_user_by_nick(nick)

    case target_user do
      nil ->
        send_no_such_nick_error(user, nick)

      target_user ->
        if MapSet.member?(current_accepted_pids, target_user.uid) or
             UserAccepts.get_by_user_pid_and_accepted_uid(user.pid, target_user.uid) != nil do
          UserAccepts.delete_by_user_pid_and_accepted_uid(user.pid, target_user.uid)
          send_removed_confirmation(user, nick)
        else
          send_not_accepted_error(user, nick)
        end
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

    if accept_list == [] do
      send_accept_list_end(user)
    else
      send_accept_list_entries(user, accept_list)
      send_accept_list_end(user)
    end
  end

  @spec send_accept_list_entries(User.t(), [UserAccept.t()]) :: :ok
  defp send_accept_list_entries(user, accepts) do
    Enum.each(accepts, fn accept ->
      case accepted_user(accept) do
        nil ->
          :ok

        accepted_user ->
          %Message{command: :rpl_acceptlist, params: [user.nick, accepted_user.nick], trailing: ""}
          |> Dispatcher.broadcast(:server, user)
      end
    end)
  end

  defp accepted_uid(%{accepted_user_uid: uid}) when is_binary(uid), do: uid

  defp accepted_uid(%{accepted_user_pid: pid}) when is_pid(pid) do
    case Users.uid_for_pid(pid) do
      {:ok, uid} -> uid
      _ -> nil
    end
  end

  defp accepted_uid(_accept), do: nil

  defp accepted_user(accept) do
    uid = accepted_uid(accept)

    cond do
      is_nil(uid) ->
        nil

      true ->
        case Users.get_by_uid(uid) do
          {:ok, user} -> user
          _ -> network_user_by_uid(uid)
        end
    end
  end

  defp network_user_by_nick(nick) do
    case Process.whereis(Manager) do
      nil ->
        nil

      manager ->
        with {:ok, runtime} <- View.runtime(manager),
             {:ok, _uid, user} <- View.user_by_nick(runtime, nick) do
          user
        else
          _ -> nil
        end
    end
  end

  defp network_user_by_uid(uid) do
    case Process.whereis(Manager) do
      nil ->
        nil

      manager ->
        with {:ok, runtime} <- View.runtime(manager),
             {:ok, user} <- View.user(runtime, uid) do
          user
        else
          _ -> nil
        end
    end
  end

  @spec send_accept_list_end(User.t()) :: :ok
  defp send_accept_list_end(user) do
    %Message{command: :rpl_acceptlistend, params: [user.nick], trailing: "End of accept list"}
    |> Dispatcher.broadcast(:server, user)
  end
end
