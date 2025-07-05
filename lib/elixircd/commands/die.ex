defmodule ElixIRCd.Commands.Die do
  @moduledoc """
  This module defines the DIE command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Operators

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "DIE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "DIE", trailing: reason}) do
    case Operators.has_operator_privilege?(user, :die) do
      true -> handle_die(reason)
      false -> noprivileges_message(user)
    end
  end

  @dialyzer {:no_return, handle_die: 1}
  @spec handle_die(String.t() | nil) :: :ok
  defp handle_die(reason) do
    all_users = Users.get_all()
    formatted_reason = if is_nil(reason), do: "", else: ": #{reason}"
    shutdown_message = "Server is shutting down#{formatted_reason}"

    Message.build(%{prefix: :server, command: "NOTICE", params: ["*"], trailing: shutdown_message})
    |> Dispatcher.broadcast(all_users)

    # The current process will be stopped, so the shutdown needs to be executed
    # in a non-linked process. The shutdown is delayed by 100 milliseconds, so
    # the server can send the shutdown message to all users before halting.
    spawn(fn ->
      Process.sleep(100)
      System.halt(0)
    end)

    Enum.each(all_users, fn user ->
      closing_link_message(user, shutdown_message)
      send(user.pid, {:disconnect, shutdown_message})
    end)
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
