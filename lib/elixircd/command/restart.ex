defmodule ElixIRCd.Command.Restart do
  @moduledoc """
  This module defines the RESTART command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [build_user_mask: 1, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "RESTART"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "RESTART", trailing: reason}) do
    case irc_operator?(user) do
      true -> handle_restart(reason)
      false -> noprivileges_message(user)
    end
  end

  @spec handle_restart(String.t() | nil) :: :ok
  defp handle_restart(reason) do
    all_users = Users.get_all()
    formatted_reason = if is_nil(reason), do: "", else: ": #{reason}"
    restart_message = "Server is restarting#{formatted_reason}"

    Message.build(%{prefix: :server, command: "NOTICE", params: ["*"], trailing: restart_message})
    |> Messaging.broadcast(all_users)

    Enum.each(all_users, fn user ->
      closing_link_message(user, restart_message)
      send(user.pid, {:disconnect, user.socket, restart_message})
    end)

    Process.sleep(1000)
    Application.stop(:elixircd)
    Application.start(:elixircd)
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

  @spec closing_link_message(User.t(), String.t()) :: :ok
  defp closing_link_message(user, message) do
    Message.build(%{
      prefix: :server,
      command: "ERROR",
      params: [],
      trailing: "Closing Link: #{build_user_mask(user)} (#{message})"
    })
    |> Messaging.broadcast(user)
  end
end
