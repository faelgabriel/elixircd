defmodule ElixIRCd.Commands.Rehash do
  @moduledoc """
  This module defines the REHASH command.

  REHASH reloads the server configuration. Only IRC operators can use this command.
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
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
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
    %Message{command: :rpl_rehashing, params: [user.nick, "elixircd.exs"], trailing: "Rehashing"}
    |> Dispatcher.broadcast(:server, user)

    load_configurations()

    %Message{command: "NOTICE", params: [user.nick], trailing: "Rehashing completed"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec noprivileges_message(User.t()) :: :ok
  defp noprivileges_message(user) do
    %Message{command: :err_noprivileges, params: [user.nick], trailing: "Permission Denied- You're not an IRC operator"}
    |> Dispatcher.broadcast(:server, user)
  end
end
