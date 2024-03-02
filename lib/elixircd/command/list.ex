defmodule ElixIRCd.Command.List do
  @moduledoc """
  This module defines the LIST command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "LIST"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "LIST", params: []}) do
    # If the user is registered and requests the list without any specific channel
    # 321 to start the list and 322 for each channel, 323 to end the list
  end

  @impl true
  def handle(user, %{command: "LIST", params: [channel_patterns | _rest]}) do
    # If the user requests the list with a specific channels or patterns
    # 321 to start the list and 322 for each matching channel, 323 to end the list
  end
end
