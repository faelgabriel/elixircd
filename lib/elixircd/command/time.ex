defmodule ElixIRCd.Command.Time do
  @moduledoc """
  This module defines the TIME command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TIME"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "TIME"}) do
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]
    current_time = DateTime.utc_now() |> Calendar.strftime("%A %B %d %Y -- %H:%M:%S %Z")

    Message.build(%{
      prefix: :server,
      command: :rpl_time,
      params: [user.nick, server_hostname],
      trailing: current_time
    })
    |> Dispatcher.broadcast(user)
  end
end
