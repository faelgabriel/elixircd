defmodule ElixIRCd.Command.Wallops do
  @moduledoc """
  This module defines the WALLOPS command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [build_user_mask: 1, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "WALLOPS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WALLOPS", trailing: nil}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "WALLOPS"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WALLOPS", trailing: message}) do
    case irc_operator?(user) do
      true -> wallops_message(user, message)
      false -> noprivileges_message(user)
    end
  end

  @spec wallops_message(User.t(), String.t()) :: :ok
  defp wallops_message(user, message) do
    target_users = Users.get_by_mode("w")

    Message.build(%{
      prefix: build_user_mask(user),
      command: "WALLOPS",
      params: [],
      trailing: message
    })
    |> Messaging.broadcast(target_users)
  end

  @spec noprivileges_message(User.t()) :: :ok
  defp noprivileges_message(user) do
    Message.build(%{
      prefix: :server,
      command: :err_noprivileges,
      params: [user.nick],
      trailing: "Permission Denied- You're not an IRC operator"
    })
    |> Messaging.broadcast(user)
  end
end
