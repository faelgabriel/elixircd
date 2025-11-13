defmodule ElixIRCd.Commands.Globops do
  @moduledoc """
  This module defines the GLOBOPS command.

  GLOBOPS broadcasts a global operator message to all IRCops.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "GLOBOPS"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "GLOBOPS", trailing: nil}) do
    %Message{
      command: :err_needmoreparams,
      params: [user.nick, "GLOBOPS"],
      trailing: "Not enough parameters"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "GLOBOPS", trailing: message}) do
    case irc_operator?(user) do
      true -> globops_message(user, message)
      false -> noprivileges_message(user)
    end
  end

  @spec globops_message(User.t(), String.t()) :: :ok
  defp globops_message(user, message) do
    target_operators = Users.get_by_mode("o")

    %Message{
      command: "GLOBOPS",
      params: [],
      trailing: message
    }
    |> Dispatcher.broadcast(user, target_operators)
  end

  @spec noprivileges_message(User.t()) :: :ok
  defp noprivileges_message(user) do
    %Message{
      command: "481",
      params: [user.nick],
      trailing: "Permission Denied- You're not an IRC operator"
    }
    |> Dispatcher.broadcast(:server, user)
  end
end
