defmodule ElixIRCd.Commands.Version do
  @moduledoc """
  This module defines the VERSION command.

  VERSION returns the version information of the IRC server.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "VERSION"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "VERSION"}) do
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]
    elixircd_version = Application.spec(:elixircd, :vsn)

    Message.build(%{
      prefix: :server,
      command: :rpl_version,
      params: [user.nick, "ElixIRCd-#{elixircd_version}", server_hostname]
    })
    |> Dispatcher.broadcast(user)
  end
end
