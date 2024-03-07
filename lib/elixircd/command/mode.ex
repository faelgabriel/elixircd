defmodule ElixIRCd.Command.Mode do
  @moduledoc """
  This module defines the Mode command.
  """

  @behaviour ElixIRCd.Command

  # alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "MODE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "MODE"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  # @impl true
  # def handle(_user, %{command: "MODE", params: [_target], trailing: nil}) do
  #   # Future
  #   :ok
  # end

  # @impl true
  # def handle(user, %{command: "MODE", params: [target, mode_string], trailing: nil}) do
  #   case Helper.channel_name?(target) do
  #     true -> handle_channel_mode(user, target, mode_string)
  #     false -> handle_user_mode(user, target, mode_string)
  #   end
  # end

  # defp handle_channel_mode(_user, _channel_name, _mode_string) do
  #   # Future
  #   :ok
  # end

  # defp handle_user_mode(_user, _receiver_nick, _mode_string) do
  #   # Future
  #   :ok
  # end
end
