defmodule ElixIRCd.Commands.Mode do
  @moduledoc """
  This module defines the Mode command.
  """

  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder
  alias ElixIRCd.Message.MessageHelpers

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "MODE"}) do
    MessageBuilder.server_message(:err_notregistered, ["*"], "You have not registered")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: [target], body: nil}) do
    MessageHelpers.extract_targets(target)
    |> case do
      {:channels, channel_names} ->
        Enum.each(channel_names, &handle_channel_mode(user, &1))

      {:users, target_nicks} ->
        Enum.each(target_nicks, &handle_user_mode(user, &1))

      {:error, error_message} ->
        MessageBuilder.server_message(:err_nosuchchannel, [user.nick, target], error_message)
        |> Messaging.send_message(user)
    end
  end

  @impl true
  def handle(user, %{command: "MODE"}) do
    MessageBuilder.server_message(:rpl_needmoreparams, [user.nick, "MODE"], "Not enough parameters")
    |> Messaging.send_message(user)
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
