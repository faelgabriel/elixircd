defmodule ElixIRCd.Commands.Oper do
  @moduledoc """
  This module defines the OPER command.

  OPER allows users to gain IRC operator privileges by providing credentials.
  """

  @behaviour ElixIRCd.Command

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Operators
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Snotice
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "OPER"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "OPER", params: params}) when length(params) <= 1 do
    %Message{command: :err_needmoreparams, params: [user.nick, "OPER"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "OPER", params: [username, password | _rest]}) do
    # REHASH and operator changes read the User table to revoke sessions; this write lock
    # keeps authentication ordered with revocation until the command transaction commits.
    case Users.lock_by_pid(user.pid) do
      nil -> :ok
      current_user -> authenticate(current_user, username, password)
    end
  end

  @spec authenticate(User.t(), String.t(), String.t()) :: :ok
  defp authenticate(user, username, password) do
    case Operators.Authentication.authenticate(username, password) do
      {:ok, credential} ->
        Observability.defer([:security], %{count: 1}, %{action: :oper, result: :success})
        Logger.info("operator authenticated", event: "audit.oper", actor: username, result: :success)

        updated_user =
          Users.update(user, %{
            modes: Enum.uniq([:o | user.modes]),
            oper_source: credential.source,
            oper_name: credential.name
          })

        %Message{command: :rpl_youreoper, params: [updated_user.nick], trailing: "You are now an IRC operator"}
        |> Dispatcher.broadcast(:server, updated_user)

        %Message{command: "MODE", params: [updated_user.nick, "+o"]}
        |> Dispatcher.broadcast(:server, updated_user)

        send_oper_success_snotice(updated_user, username)

      :error ->
        Observability.defer([:security], %{count: 1}, %{action: :oper, result: :failure})
        Logger.warning("operator authentication failed", event: "audit.oper", result: :failure)

        %Message{command: :err_passwdmismatch, params: [user.nick], trailing: "Password incorrect"}
        |> Dispatcher.broadcast(:server, user)

        send_oper_failure_snotice(user, username)
    end
  end

  @spec send_oper_success_snotice(User.t(), String.t()) :: :ok
  defp send_oper_success_snotice(user, username) do
    user_info = Snotice.format_user_info(user)
    Snotice.broadcast(:oper, "#{user_info} opered as #{username}")
  end

  @spec send_oper_failure_snotice(User.t(), String.t()) :: :ok
  defp send_oper_failure_snotice(user, username) do
    user_info = Snotice.format_user_info(user)
    Snotice.broadcast(:oper, "Failed OPER attempt by #{user_info} (username: #{username})")
  end
end
