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
  def handle(user, %{command: "MODE", params: [target], body: nil}) do
    Helper.get_target_list(target)
    |> case do
      {:channels, channel_names} ->
        Enum.each(channel_names, &handle_channel_mode(user, &1))

      {:users, target_nicks} ->
        Enum.each(target_nicks, &handle_user_mode(user, &1))

      {:error, error_message} ->
        Message.new(%{source: :server, command: :err_nosuchchannel, params: [user.nick, target], body: error_message})
        |> Server.send_message(user)
    end
  end

  @impl true
  def handle(user, %{command: "MODE"}) do
    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user.nick, "MODE"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
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
