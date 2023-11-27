defmodule ElixIRCd.Core.Messaging do
  @moduledoc """
  Module for handling IRC messages.
  """

  alias ElixIRCd.Core.Server
  alias ElixIRCd.Data.Schemas

  @doc """
  Sends a message to a user in the form of a server message or a user message.
  """
  @spec send_message(Schemas.User.t(), atom(), String.t()) :: :ok
  def send_message(user, :server, message) do
    server_name = Server.server_name()
    Server.send_packet(user, ":#{server_name} #{message}")
  end

  def send_message(user, :user, message) do
    Server.send_packet(user, ":#{user.identity} #{message}")
  end

  @doc """
  Broadcasts a message to all users except for the excluded user.
  """
  @spec broadcast_except_for_user([Schemas.User.t()], Schemas.User.t(), String.t()) :: :ok
  def broadcast_except_for_user(users, excluded_user, message) do
    Enum.each(users, fn user ->
      if user != excluded_user do
        Server.send_packet(user, message)
      end
    end)
  end

  @doc """
  Broadcasts a message to all users.
  """
  @spec broadcast([Schemas.User.t()], String.t()) :: :ok
  def broadcast(users, message) do
    Enum.each(users, fn user ->
      Server.send_packet(user, message)
    end)
  end

  @doc """
  Sends a message to the user that parameters are missing.
  """
  @spec message_not_enough_params(Schemas.User.t(), String.t()) :: :ok
  def message_not_enough_params(user, command) do
    send_message(user, :server, "461 #{command} :Not enough parameters")
  end

  @doc """
  Sends a message to the user that he is not registered and cannot use the command.
  """
  @spec message_not_registered(Schemas.User.t()) :: :ok
  def message_not_registered(user) do
    send_message(user, :server, "451 :You have not registered")
  end
end
