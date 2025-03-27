defmodule ElixIRCd.Command.Lusers do
  @moduledoc """
  This module defines the LUSERS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.Metrics
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "LUSERS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "LUSERS"}) do
    send_lusers(user)
  end

  @doc """
  Sends the LUSERS information to the user.
  """
  @spec send_lusers(User.t()) :: :ok
  def send_lusers(user) do
    %{visible: visible, invisible: invisible, operators: operators, unknown: unknown, total: total_users} =
      Users.count_all_states()

    total_channels = Channels.count_all()
    highest_connections = Metrics.get(:highest_connections)

    [
      Message.build(%{
        prefix: :server,
        command: :rpl_luserclient,
        params: [user.nick],
        trailing: "There are #{visible} users and #{invisible} invisible on 1 server"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_luserop,
        params: [user.nick, to_string(operators)],
        trailing: "operator(s) online"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_luserunknown,
        params: [user.nick, to_string(unknown)],
        trailing: "unknown connection(s)"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_luserchannels,
        params: [user.nick, to_string(total_channels)],
        trailing: "channels formed"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_luserme,
        params: [user.nick],
        trailing: "I have #{total_users} clients and 0 servers"
      }),
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
