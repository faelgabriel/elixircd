defmodule ElixIRCd.Command.Users do
  @moduledoc """
  This module defines the USERS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Metrics
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "USERS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "USERS"}) do
    total_users = Users.count_all()
    highest_connections = Metrics.get(:highest_connections)

    [
      Message.build(%{
        prefix: :server,
        command: :rpl_localusers,
        params: [user.nick, to_string(total_users), to_string(highest_connections)],
        trailing: "Current local users #{total_users}, max #{highest_connections}"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_globalusers,
        params: [user.nick, to_string(total_users), to_string(highest_connections)],
        trailing: "Current global users #{total_users}, max #{highest_connections}"
      })
    ]
    |> Dispatcher.broadcast(user)
  end
end
