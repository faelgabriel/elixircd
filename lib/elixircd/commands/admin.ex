defmodule ElixIRCd.Commands.Admin do
  @moduledoc """
  This module defines the ADMIN command.

  ADMIN returns administrative information about the server.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "ADMIN"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "ADMIN"}) do
    [
      %Message{
        command: :rpl_adminme,
        params: [user.nick],
        trailing: "Administrative info about #{Application.get_env(:elixircd, :admin_info)[:server]}"
      },
      %Message{
        command: :rpl_adminloc1,
        params: [user.nick],
        trailing: Application.get_env(:elixircd, :admin_info)[:location]
      },
      %Message{
        command: :rpl_adminloc2,
        params: [user.nick],
        trailing: Application.get_env(:elixircd, :admin_info)[:organization]
      },
      %Message{
        command: :rpl_adminemail,
        params: [user.nick],
        trailing: Application.get_env(:elixircd, :admin_info)[:email]
      }
    ]
    |> Dispatcher.broadcast(:server, user)
  end
end
