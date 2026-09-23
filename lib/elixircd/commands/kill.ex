defmodule ElixIRCd.Commands.Kill do
  @moduledoc """
  This module defines the KILL command.

  KILL forcibly disconnects a user from the server. Only IRC operators can use this command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Server.Snotice
  alias ElixIRCd.Server.S2S.Action
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "KILL"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "KILL", params: []}) do
    %Message{command: :err_needmoreparams, params: [user.nick, "KILL"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "KILL", params: [target_nick | _rest], trailing: reason, tags: tags}) do
    with {:irc_operator?, true} <- {:irc_operator?, irc_operator?(user)} do
      response_context = Action.response_context(user, tags, "KILL target server is unavailable")

      case remote_target_context(target_nick) do
        {:ok, manager, runtime, target_uid, target_user, target_sid} ->
          remote_kill(user, manager, runtime, target_uid, target_user, target_sid, reason, response_context)

        :local ->
          local_kill(user, target_nick, reason)
      end
    else
      {:irc_operator?, false} -> noprivileges_message(user)
    end
  end

  defp local_kill(user, target_nick, reason) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} ->
        formatted_reason = if is_nil(reason), do: "", else: " (#{reason})"
        killed_message = "Killed (#{user.nick}#{formatted_reason})"

        closing_link_message(target_user, killed_message)
        send_kill_snotice(user, target_user, reason)
        Dispatcher.disconnect(target_user, killed_message)

        :ok

      {:error, :user_not_found} ->
        target_not_found_message(user, target_nick)
    end
  end

  defp remote_kill(user, manager, runtime, target_uid, target_user, target_sid, reason, response_context) do
    args = %{
      "action" => "kill",
      "target_uid" => target_uid,
      "value" => nil,
      "reason" => Action.reason(reason)
    }

    guards = %{
      "actor_uid" => user.uid,
      "actor_user_rev" => user.owner_rev,
      "actor_join_id" => nil,
      "target_user_rev" => target_user.owner_rev,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => runtime.policy.epoch,
      "policy_revision" => runtime.policy.revision
    }

    case Action.enqueue(manager, target_sid, user, "user_action", args, guards, response_context) do
      :queued ->
        ResponseContext.defer_response(user)
        :ok

      {:error, _reason} ->
        send_remote_error(user, "KILL target server is unavailable")
    end
  end

  defp remote_target_context(target_nick) do
    with manager when is_pid(manager) <- Process.whereis(Manager),
         {:ok, runtime} <- View.runtime(manager),
         {:ok, target_uid, target_user, target_sid} <- Action.remote_target(runtime, target_nick) do
      {:ok, manager, runtime, target_uid, target_user, target_sid}
    else
      :local -> :local
      {:error, :not_found} -> :local
      _ -> :local
    end
  end

  defp send_remote_error(user, message) do
    %Message{command: "NOTICE", params: [user.nick], trailing: message}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_kill_snotice(User.t(), User.t(), String.t() | nil) :: :ok
  defp send_kill_snotice(oper, target, reason) do
    snotice_reason = if is_nil(reason), do: "No reason given", else: reason
    oper_info = Snotice.format_user_info(oper)
    target_info = Snotice.format_user_info(target)
    Snotice.broadcast(:kill, "Local kill by #{oper_info} for #{target_info} (#{snotice_reason})")
  end

  @spec closing_link_message(User.t(), String.t()) :: :ok
  defp closing_link_message(target_user, killed_message) do
    %Message{command: "ERROR", params: [], trailing: "Closing Link: #{user_mask(target_user)} (#{killed_message})"}
    |> Dispatcher.broadcast(:server, target_user)
  end

  @spec noprivileges_message(User.t()) :: :ok
  defp noprivileges_message(user) do
    %Message{command: :err_noprivileges, params: [user.nick], trailing: "Permission Denied- You're not an IRC operator"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec target_not_found_message(User.t(), String.t()) :: :ok
  defp target_not_found_message(user, target) do
    %Message{command: :err_nosuchnick, params: [user.nick, target], trailing: "No such nick"}
    |> Dispatcher.broadcast(:server, user)
  end
end
