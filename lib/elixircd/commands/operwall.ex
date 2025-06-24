defmodule ElixIRCd.Commands.Operwall do
  @moduledoc """
  This module defines the OPERWALL command.

  OPERWALL is a server-to-operators wall message. It allows IRC operators to broadcast
  a message to all other operators across the network. It is not visible to normal users,
  only to IRC operators (+o users) who have the right user mode and permissions.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "OPERWALL"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "OPERWALL", trailing: nil}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "OPERWALL"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "OPERWALL", trailing: message}) do
    case irc_operator?(user) do
      true -> operwall_message(user, message)
      false -> noprivileges_message(user)
    end
  end

  @spec operwall_message(User.t(), String.t()) :: :ok
  defp operwall_message(_sender, message) do
    target_operators = Users.get_by_mode("o")

    Message.build(%{
      prefix: :server,
      command: "NOTICE",
      params: ["$opers"],
      trailing: message
    })
    |> Dispatcher.broadcast(target_operators)
  end

  @spec noprivileges_message(User.t()) :: :ok
  defp noprivileges_message(user) do
    Message.build(%{
      prefix: :server,
      command: :err_noprivileges,
      params: [user.nick],
      trailing: "Permission Denied- You're not an IRC operator"
    })
    |> Dispatcher.broadcast(user)
  end
end
