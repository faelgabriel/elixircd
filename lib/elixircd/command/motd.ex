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
  def handle(%{registered: false} = user, %{command: "MOTD"}) do
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
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]

    Message.build(%{
      prefix: :server,
      command: :rpl_motdstart,
      params: [user.nick],
      trailing: "#{server_hostname} Message of the Day"
    })
    |> Messaging.broadcast(user)

    Application.get_env(:elixircd, :server)[:motd]
    |> case do
      nil ->
        Message.build(%{prefix: :server, command: :err_nomotd, params: [user.nick], trailing: "MOTD is missing"})

      content ->
        content
        |> String.split(~r/\R/, trim: true)
        |> Enum.map(&Message.build(%{prefix: :server, command: :rpl_motd, params: [user.nick], trailing: &1}))
    end
    |> Messaging.broadcast(user)

    Message.build(%{prefix: :server, command: :rpl_endofmotd, params: [user.nick], trailing: "End of /MOTD command"})
    |> Messaging.broadcast(user)
  end
end
