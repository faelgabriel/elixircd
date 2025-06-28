defmodule ElixIRCd.Utils.ServerNotice do
  @moduledoc """
  Utility functions for sending server notices based on snomasks.
  """

  alias ElixIRCd.Commands.Mode.UserModes
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @doc """
  Send a server notice to all users with a specific snomask.
  """
  @spec send_notice(String.t(), String.t()) :: :ok
  def send_notice(snomask, message) when is_binary(snomask) and is_binary(message) do
    target_users = UserModes.get_users_with_snomask(snomask)

    if length(target_users) > 0 do
      Message.build(%{
        prefix: :server,
        command: "NOTICE",
        params: ["*"],
        trailing: message
      })
      |> Dispatcher.broadcast(target_users)
    end

    :ok
  end

  @spec send_notice([String.t()], String.t()) :: :ok
  def send_notice(snomasks, message) when is_list(snomasks) and is_binary(message) do
    target_users =
      snomasks
      |> Enum.flat_map(&UserModes.get_users_with_snomask/1)
      |> Enum.uniq_by(& &1.pid)

    if length(target_users) > 0 do
      Message.build(%{
        prefix: :server,
        command: "NOTICE",
        params: ["*"],
        trailing: message
      })
      |> Dispatcher.broadcast(target_users)
    end

    :ok
  end

  @doc """
  Send a connect notice (snomask 'c').
  """
  @spec send_connect_notice(User.t()) :: :ok
  def send_connect_notice(user) do
    hostname = user.hostname || "unknown"
    ident = user.ident || "unknown"
    message = "*** Notice -- Client connecting: #{user.nick} (#{ident}@#{hostname}) [#{:inet.ntoa(user.ip_address)}]"
    send_notice("c", message)
  end

  @doc """
  Send a disconnect notice (snomask 'c').
  """
  @spec send_disconnect_notice(User.t(), String.t()) :: :ok
  def send_disconnect_notice(user, reason \\ "Client Quit") do
    hostname = user.hostname || "unknown"
    ident = user.ident || "unknown"
    message = "*** Notice -- Client exiting: #{user.nick} (#{ident}@#{hostname}) [#{:inet.ntoa(user.ip_address)}] (#{reason})"
    send_notice("c", message)
  end

  @doc """
  Send a kill notice (snomask 'k').
  """
  @spec send_kill_notice(User.t(), User.t(), String.t()) :: :ok
  def send_kill_notice(operator, target, reason) do
    hostname = target.hostname || "unknown"
    ident = target.ident || "unknown"
    message = "*** Notice -- Received KILL message for #{target.nick} (#{ident}@#{hostname}) from #{operator.nick} (#{reason})"
    send_notice("k", message)
  end

  @doc """
  Send an operator notice (snomask 'o').
  """
  @spec send_oper_notice(User.t()) :: :ok
  def send_oper_notice(user) do
    hostname = user.hostname || "unknown"
    ident = user.ident || "unknown"
    message = "*** Notice -- #{user.nick} (#{ident}@#{hostname}) is now an IRC operator"
    send_notice("o", message)
  end

  @doc """
  Send a general server notice (snomask 's').
  """
  @spec send_server_notice(String.t()) :: :ok
  def send_server_notice(message) do
    send_notice("s", "*** Notice -- #{message}")
  end
end
