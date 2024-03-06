defmodule ElixIRCd.Command.Motd do
  @moduledoc """
  This module defines the MOTD command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "MOTD"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "MOTD"}) do
    send_motd(user)
  end

  @doc """
  Sends the Message of the Day to the user.
  """
  @spec send_motd(User.t()) :: :ok
  def send_motd(user) do
    server_name = Application.get_env(:elixircd, :server_name)

    [
      Message.build(%{
        prefix: :server,
        command: :rpl_welcome,
        params: [user.nick],
        trailing: "Welcome to the #{server_name} Internet Relay Chat Network #{user.nick}"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_yourhost,
        params: [user.nick],
        trailing: "Your host is #{server_name}, running version 0.1.0."
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_created,
        params: [user.nick],
        trailing: "This server was created #{DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()}"
      }),
      Message.build(%{prefix: :server, command: :rpl_myinfo, params: [user.nick], trailing: "ElixIRCd 0.1.0 +i +int"}),
      Message.build(%{prefix: :server, command: :rpl_endofmotd, params: [user.nick], trailing: "End of MOTD command"})
    ]
    |> Messaging.broadcast(user)
  end
end
