defmodule ElixIRCd.Repository.UserChannels do
  @moduledoc """
  Module for the user channels repository.
  """

  alias ElixIRCd.Tables.UserChannel

  @spec create(map()) :: UserChannel.t()
  def create(attrs) do
    UserChannel.new(attrs)
    |> Memento.Query.write()
  end

  @spec delete(UserChannel.t()) :: :ok
  def delete(user_channel) do
    Memento.Query.delete_record(user_channel)
  end

  @spec delete_by_user_port(port()) :: :ok
  def delete_by_user_port(user_port) do
    Memento.Query.delete(UserChannel, user_port)
  end

  @spec get_by_user_port_and_channel_name(port(), String.t()) :: {:ok, UserChannel.t()} | {:error, String.t()}
  def get_by_user_port_and_channel_name(user_port, channel_name) do
    conditions = [{:==, :user_port, user_port}, {:==, :channel_name, channel_name}]

    Memento.Query.select(UserChannel, conditions, limit: 1)
    |> case do
      [] -> {:error, "UserChannel not found"}
      [user_channel] -> {:ok, user_channel}
    end
  end

  @spec get_by_user_port(port()) :: [UserChannel.t()]
  def get_by_user_port(user_port) do
    Memento.Query.select(UserChannel, {:==, :user_port, user_port})
  end

  @spec get_by_channel_name(String.t()) :: [UserChannel.t()]
  def get_by_channel_name(channel_name) do
    Memento.Query.select(UserChannel, {:==, :channel_name, channel_name})
  end

  @spec get_by_channel_names([String.t()]) :: [UserChannel.t()]
  def get_by_channel_names([]), do: []

  def get_by_channel_names(channel_names) do
    conditions =
      Enum.map(channel_names, fn channel_name -> {:==, :channel_name, channel_name} end)
      |> Enum.reduce(fn condition, acc -> {:or, condition, acc} end)

    Memento.Query.select(UserChannel, conditions)
  end
end
