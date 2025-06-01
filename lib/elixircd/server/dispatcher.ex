defmodule ElixIRCd.Server.Dispatcher do
  @moduledoc """
  Module for dispatching messages to users.
  """

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type target :: pid() | User.t() | UserChannel.t()

  @doc """
  Broadcasts messages to the given targets.
  Targets can be a single target or a list of pids, users or user_channels.
  """
  @spec broadcast(Message.t() | [Message.t()], target() | [target()]) :: :ok
  def broadcast(messages, targets) when is_list(messages) and is_list(targets) do
    messages |> Enum.each(&broadcast(&1, targets))
    :ok
  end

  def broadcast(message, targets) when not is_list(message) and is_list(targets) do
    raw_message = Message.unparse!(message)
    targets |> Enum.each(&send_packet(&1, raw_message))
  end

  def broadcast(messages, target) when is_list(messages) and not is_list(target) do
    messages |> Enum.each(&broadcast(&1, target))
  end

  def broadcast(message, target) when not is_list(message) and not is_list(target) do
    raw_message = Message.unparse!(message)
    send_packet(target, raw_message)
  end

  @spec send_packet(target(), String.t()) :: :ok
  defp send_packet(pid, raw_message) when is_pid(pid), do: Connection.handle_send(pid, raw_message)
  defp send_packet(%User{pid: pid}, raw_message), do: Connection.handle_send(pid, raw_message)
  defp send_packet(%UserChannel{user_pid: pid}, raw_message), do: Connection.handle_send(pid, raw_message)
end
