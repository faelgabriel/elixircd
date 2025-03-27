defmodule ElixIRCd.Command.Admin do
  @moduledoc """
  This module defines the ADMIN command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "ADMIN"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "ADMIN"}) do
    [
      Message.build(%{
        prefix: :server,
        command: :rpl_adminme,
        params: [user.nick],
        trailing: "Administrative info about #{Application.get_env(:elixircd, :admin_info)[:server]}"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_adminloc1,
        params: [user.nick],
        trailing: Application.get_env(:elixircd, :admin_info)[:location]
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_adminloc2,
        params: [user.nick],
        trailing: Application.get_env(:elixircd, :admin_info)[:organization]
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_adminemail,
        params: [user.nick],
        trailing: Application.get_env(:elixircd, :admin_info)[:email]
      })
    ]
    |> Dispatcher.broadcast(user)
  end
end
