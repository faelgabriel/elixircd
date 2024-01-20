defmodule ElixIRCd.Command.Mode do
  @moduledoc """
  This module defines the Mode command.
  """

  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  @behaviour ElixIRCd.Command

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "MODE"}) do
    Message.new(%{source: :server, command: :err_notregistered, params: ["*"], body: "You have not registered"})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: []}) do
    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user.nick, "MODE"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: [target], body: nil}) do
    case Helper.channel_name?(target) do
      true -> handle_channel_mode(user, target)
      false -> handle_user_mode(user, target)
    end
  end

  defp handle_channel_mode(_user, _channel_name) do
    # Future
    :ok
  end

  defp handle_user_mode(_user, _receiver_nick) do
    # Future
    :ok
  end
end
