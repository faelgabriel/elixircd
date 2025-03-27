defmodule ElixIRCd.Command.Die do
  @moduledoc """
  This module defines the DIE command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "DIE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "DIE", trailing: reason}) do
    case irc_operator?(user) do
      true -> handle_die(reason)
      false -> noprivileges_message(user)
    end
  end

  @spec handle_die(String.t() | nil) :: no_return()
  defp handle_die(reason) do
    all_users = Users.get_all()
    formatted_reason = if is_nil(reason), do: "", else: ": #{reason}"
    shutdown_message = "Server is shutting down#{formatted_reason}"

    Message.build(%{prefix: :server, command: "NOTICE", params: ["*"], trailing: shutdown_message})
    |> Dispatcher.broadcast(all_users)

    Enum.each(all_users, fn user ->
      closing_link_message(user, shutdown_message)
      send(user.pid, {:disconnect, shutdown_message})
    end)

    Process.sleep(1000)
    System.halt(0)
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

  @spec closing_link_message(User.t(), String.t()) :: :ok
  defp closing_link_message(user, message) do
    Message.build(%{
      prefix: :server,
      command: "ERROR",
      params: [],
      trailing: "Closing Link: #{user_mask(user)} (#{message})"
    })
    |> Dispatcher.broadcast(user)
  end
end
