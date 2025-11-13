defmodule ElixIRCd.Commands.Restart do
  @moduledoc """
  This module defines the RESTART command.

  RESTART restarts the IRC server. Only IRC operators can use this command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "RESTART"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
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

    %Message{command: "NOTICE", params: ["*"], trailing: restart_message}
    |> Dispatcher.broadcast(:server, all_users)

    # The current process will be stopped, so the restart needs to be executed
    # in a non-linked process. The restart is delayed by 100 milliseconds, so
    # the server can send the restart message to all users before restarting.
    spawn(fn ->
      Process.sleep(100)
      Application.stop(:elixircd)
      Application.start(:elixircd)
    end)

    Enum.each(all_users, fn user ->
      closing_link_message(user, restart_message)
      send(user.pid, {:disconnect, restart_message})
    end)
  end

  @spec noprivileges_message(User.t()) :: :ok
  defp noprivileges_message(user) do
    %Message{command: :err_noprivileges, params: [user.nick], trailing: "Permission Denied- You're not an IRC operator"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec closing_link_message(User.t(), String.t()) :: :ok
  defp closing_link_message(user, message) do
    %Message{command: "ERROR", params: [], trailing: "Closing Link: #{user_mask(user)} (#{message})"}
    |> Dispatcher.broadcast(:server, user)
  end
end
