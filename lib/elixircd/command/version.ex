defmodule ElixIRCd.Command.Version do
  @moduledoc """
  This module defines the VERSION command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "VERSION"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "VERSION"}) do
    # Scenario: Client queries for server version
    # Respond with RPL_VERSION (351), providing the version of the IRCd,
    # the server's name, and optionally, a comment field with additional information.
    # The format for RPL_VERSION is "<version>.<debuglevel> <server> :<comments>"
    # Example response might be "ElixIRCd-1.0.0 0 irc.example.com :Elixir based IRCd"
    :ok
  end
end
