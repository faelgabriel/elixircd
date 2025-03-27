defmodule ElixIRCd.Commands.Trace do
  @moduledoc """
  This module defines the TRACE command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]
  import ElixIRCd.Utils.Network, only: [format_ip_address: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TRACE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "TRACE", params: []}) do
    send_trace(user, user)
  end

  @impl true
  def handle(user, %{command: "TRACE", params: [target | _rest]}) do
    case Users.get_by_nick(target) do
      {:ok, target_user} -> send_trace(user, target_user)
      {:error, :user_not_found} -> send_target_not_found(user, target)
    end
  end

  @spec send_trace(User.t(), User.t()) :: :ok
  defp send_trace(user, target_user) do
    mask = user_mask(target_user)
    formatted_ip_address = format_ip_address(target_user.ip_address)
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
    |> Dispatcher.broadcast(user)
  end

  @spec send_target_not_found(User.t(), String.t()) :: :ok
  defp send_target_not_found(user, target) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchnick,
      params: [user.nick, target],
      trailing: "No such nick"
    })
    |> Dispatcher.broadcast(user)
  end
end
