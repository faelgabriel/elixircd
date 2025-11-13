defmodule ElixIRCd.Commands.Time do
  @moduledoc """
  This module defines the TIME command.

  TIME returns the current date and time of the server.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TIME"}) do
    Message.build(%{command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "TIME"}) do
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]
    current_time = DateTime.utc_now() |> Calendar.strftime("%A %B %d %Y -- %H:%M:%S %Z")

    Message.build(%{
      command: :rpl_time,
      params: [user.nick, server_hostname],
      trailing: current_time
    })
    |> Dispatcher.broadcast(:server, user)
  end
end
