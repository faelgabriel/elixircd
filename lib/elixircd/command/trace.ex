defmodule ElixIRCd.Command.Trace do
  @moduledoc """
  This module defines the TRACE command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [build_user_mask: 1, format_ip_address: 1, get_socket_ip: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TRACE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "TRACE", params: []}) do
    handle_trace(user, user)
  end

  @impl true
  def handle(user, %{command: "TRACE", params: [target | _rest]}) do
    case Users.get_by_nick(target) do
      {:ok, target_user} -> handle_trace(user, target_user)
      {:error, :user_not_found} -> send_target_not_found(user, target)
    end
  end

  @spec handle_trace(User.t(), User.t()) :: :ok
  defp handle_trace(user, target_user) do
    case get_socket_ip(target_user.socket) do
      {:ok, ip_address} -> send_trace(user, target_user, ip_address)
      {:error, _error} -> send_target_not_found(user, target_user.nick)
    end
  end

  @spec send_trace(User.t(), User.t(), tuple()) :: :ok
  defp send_trace(user, target_user, ip_address) do
    mask = build_user_mask(target_user)
    formatted_ip_address = format_ip_address(ip_address)
    idle_seconds = (:erlang.system_time(:second) - target_user.last_activity) |> to_string()
    signon_seconds = DateTime.diff(DateTime.utc_now(), target_user.registered_at, :second) |> to_string()

    [
      Message.build(%{
        prefix: :server,
        command: :rpl_traceuser,
        params: [
          user.nick,
          "User",
          "users",
          "#{target_user.nick}[#{mask}]",
          "(#{formatted_ip_address})",
          idle_seconds,
          signon_seconds
        ]
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_traceend,
        params: [user.nick],
        trailing: "End of TRACE"
      })
    ]
    |> Messaging.broadcast(user)
  end

  @spec send_target_not_found(User.t(), String.t()) :: :ok
  defp send_target_not_found(user, target) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchnick,
      params: [user.nick, target],
      trailing: "No such nick"
    })
    |> Messaging.broadcast(user)
  end
end
