defmodule ElixIRCd.Repository.UserChannels do
  @moduledoc """
  Module for the user channels repository.
  """

  alias ElixIRCd.Tables.UserChannel

  @doc """
  Create a new user channel and write it to the database.
  """
  @spec create(map()) :: UserChannel.t()
  def create(attrs) do
    UserChannel.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Update a user channel and write it to the database.
  """
  @spec update(UserChannel.t(), map()) :: UserChannel.t()
  def update(user_channel, attrs) do
    delete(user_channel)

    UserChannel.update(user_channel, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a user channel from the database.
  """
  @spec delete(UserChannel.t()) :: :ok
  def delete(user_channel) do
    Memento.Query.delete_record(user_channel)
  end

  @doc """
  Delete a user channel by user port from the database.
  """
  @spec delete_by_user_port(port()) :: :ok
  def delete_by_user_port(user_port) do
    Memento.Query.delete(UserChannel, user_port)
  end

  @doc """
  Get a user channel by the user port and channel name.
  """
  @spec get_by_user_port_and_channel_name(port(), String.t()) :: {:ok, UserChannel.t()} | {:error, String.t()}
  def get_by_user_port_and_channel_name(user_port, channel_name) do
    conditions = [{:==, :user_port, user_port}, {:==, :channel_name, channel_name}]

    Memento.Query.select(UserChannel, conditions, limit: 1)
    |> case do
      [user_channel] -> {:ok, user_channel}
      [] -> {:error, "UserChannel not found"}
    end
  end

  @doc """
  Get all user channels by the user port.
  """
  @spec get_by_user_port(port()) :: [UserChannel.t()]
  def get_by_user_port(user_port) do
    Memento.Query.select(UserChannel, {:==, :user_port, user_port})
  end

  @doc """
  Get all user channels by the channel name.
  """
  @spec get_by_channel_name(String.t()) :: [UserChannel.t()]
  def get_by_channel_name(channel_name) do
    Memento.Query.select(UserChannel, {:==, :channel_name, channel_name})
  end

  @doc """
  Get all user channels by the channel names.
  """
  @spec get_by_channel_names([String.t()]) :: [UserChannel.t()]
  def get_by_channel_names([]), do: []

  def get_by_channel_names(channel_names) do
    conditions =
      Enum.map(channel_names, fn channel_name -> {:==, :channel_name, channel_name} end)
      |> Enum.reduce(fn condition, acc -> {:or, condition, acc} end)

    Memento.Query.select(UserChannel, conditions)
  end
end
