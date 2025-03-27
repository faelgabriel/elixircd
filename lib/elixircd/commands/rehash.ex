defmodule ElixIRCd.Commands.Rehash do
  @moduledoc """
  This module defines the REHASH command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1]
  import ElixIRCd.Utils.System, only: [load_configurations: 0]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "REHASH"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "REHASH"}) do
    case irc_operator?(user) do
      true -> process_rehashing(user)
      false -> noprivileges_message(user)
    end
  end

  @spec process_rehashing(User.t()) :: :ok
  defp process_rehashing(user) do
    Message.build(%{prefix: :server, command: :rpl_rehashing, params: [user.nick, "runtime.exs"], trailing: "Rehashing"})
    |> Dispatcher.broadcast(user)

    load_configurations()

    Message.build(%{prefix: :server, command: "NOTICE", params: [user.nick], trailing: "Rehashing completed"})
    |> Dispatcher.broadcast(user)
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
