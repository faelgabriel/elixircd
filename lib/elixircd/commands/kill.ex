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
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "KILL"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "KILL", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "KILL"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "KILL", params: [target_nick | _rest], trailing: reason}) do
    with {:irc_operator?, true} <- {:irc_operator?, irc_operator?(user)},
         {:ok, target_user} <- Users.get_by_nick(target_nick) do
      formatted_reason = if is_nil(reason), do: "", else: " (#{reason})"
      killed_message = "Killed (#{user.nick}#{formatted_reason})"

      closing_link_message(target_user, killed_message)
      send(target_user.pid, {:disconnect, killed_message})

      :ok
    else
      {:irc_operator?, false} -> noprivileges_message(user)
      {:error, :user_not_found} -> target_not_found_message(user, target_nick)
    end
  end

  @spec closing_link_message(User.t(), String.t()) :: :ok
  defp closing_link_message(target_user, killed_message) do
    Message.build(%{
      prefix: :server,
      command: "ERROR",
      params: [],
      trailing: "Closing Link: #{user_mask(target_user)} (#{killed_message})"
    })
    |> Dispatcher.broadcast(target_user)
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

  @spec target_not_found_message(User.t(), String.t()) :: :ok
  defp target_not_found_message(user, target) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchnick,
      params: [user.nick, target],
      trailing: "No such nick"
    })
    |> Dispatcher.broadcast(user)
  end
end
