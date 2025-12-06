defmodule ElixIRCd.Server.Snotice do
  @moduledoc """
  This module handles server notices (snotices).

  Server notices are messages sent by the server to users who have enabled
  the +s user mode. They provide information about server events such as
  connections, disconnections, operator actions, and administrative events.

  ## Categories

  Snotices are organized into categories. Only IRC operators with +s mode can receive snotices.

  - `:connect` - Client connections
  - `:quit` - Client disconnections
  - `:oper` - Operator-related notices (OPER success/failure)
  - `:kill` - KILL command usage
  - `:nick` - Nick changes
  - `:flood` - Flood/abuse protection events
  """

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher

  @type category ::
          :connect
          | :quit
          | :oper
          | :kill
          | :nick
          | :flood

  @doc """
  Broadcasts a server notice to all IRC operators with +s mode.
  Mode +s is restricted to operators, so all recipients are operators.
  """
  @spec broadcast(category(), String.t()) :: :ok
  def broadcast(category, message) do
    operators_with_s = Users.get_by_mode("s")

    unless operators_with_s == [] do
      formatted_message = format_message(category, message)

      %Message{command: "NOTICE", params: [], trailing: formatted_message}
      |> Dispatcher.broadcast(:server, operators_with_s)
    end

    :ok
  end

  @spec format_message(category(), String.t()) :: String.t()
  defp format_message(category, message) do
    prefix = category_prefix(category)
    "*** #{prefix}: #{message}"
  end

  @spec category_prefix(category()) :: String.t()
  defp category_prefix(:connect), do: "Connect"
  defp category_prefix(:quit), do: "Quit"
  defp category_prefix(:oper), do: "Oper"
  defp category_prefix(:kill), do: "Kill"
  defp category_prefix(:nick), do: "Nick"
  defp category_prefix(:flood), do: "Flood"

  @doc """
  Formats user information for snotices with real hostname and IP address.
  Since snotices are operator-only, always shows unmasked data.
  """
  @spec format_user_info(ElixIRCd.Tables.User.t()) :: String.t()
  def format_user_info(user) do
    ip_string = :inet.ntoa(user.ip_address) |> to_string()
    "#{user.nick}!#{user.ident}@#{user.hostname} [#{ip_string}]"
  end
end
