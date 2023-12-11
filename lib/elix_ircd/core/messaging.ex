defmodule ElixIRCd.Core.Messaging do
  @moduledoc """
  Module for handling IRC messages.
  """

  alias ElixIRCd.Core.Server
  alias ElixIRCd.Data.Tables
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageParser

  @doc """
  Sends a message to the given user or users.
  """
  @spec send_message(Message.t(), Tables.User.t() | [Tables.User.t()]) :: :ok
  # Sends a message to a single user.
  def send_message(message, %Tables.User{} = user) do
    raw_message = MessageParser.unparse!(message)
    Server.send_packet(user, raw_message)
  end

  # Sends a message to multiple users.
  def send_message(message, users) do
    raw_message = MessageParser.unparse!(message)

    Enum.each(users, fn user ->
      Server.send_packet(user, raw_message)
    end)

    :ok
  end

  @doc """
  Sends messages to the given user or users.
  """
  @spec send_messages([Message.t()], Tables.User.t() | [Tables.User.t()]) :: :ok
  # Sends messages to a single user.
  def send_messages(messages, %Tables.User{} = user) do
    Enum.each(messages, fn message ->
      raw_message = MessageParser.unparse!(message)
      Server.send_packet(user, raw_message)
    end)

    :ok
  end

  # Sends messages to multiple users.
  def send_messages(messages, users) do
    Enum.each(messages, fn message ->
      raw_message = MessageParser.unparse!(message)

      Enum.each(users, fn user ->
        Server.send_packet(user, raw_message)
      end)
    end)

    :ok
  end
end
