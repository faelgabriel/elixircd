defmodule ElixIRCd.Command.Users do
  @moduledoc """
  This module defines the USERS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "USERS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "USERS"}) do
    total_users = Users.count_all()

    # Future: add a configuration for max local and global users
    [
      Message.build(%{
        prefix: :server,
        command: :rpl_localusers,
        params: [user.nick, to_string(total_users), "1000"],
        trailing: "Current local users #{total_users}, max 1000"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_globalusers,
        params: [user.nick, to_string(total_users), "1000"],
        trailing: "Current global users #{total_users}, max 1000"
      })
    ]
    |> Messaging.broadcast(user)
  end
end
