defmodule ElixIRCd.Contexts.UserChannel do
  @moduledoc """
  Module for the UserChannel contexts.
  """

  alias ElixIRCd.Data.Tables.Channel
  alias ElixIRCd.Data.Tables.User
  alias ElixIRCd.Data.Tables.UserChannel

  require Logger

  @doc """
  Creates a new user_channel
  """
  @spec create(map()) :: {:ok, UserChannel.t()} | {:error, String.t()}
  def create(attrs) do
    %UserChannel{}
    |> UserChannel.changeset(attrs)
    |> Memento.Query.write()
    |> case do
      %UserChannel{} = user_channel -> {:ok, user_channel}
      error -> {:error, "UserChannel not created: #{error}"}
    end
  end

  @doc """
  Deletes a user_channel
  """
  @spec delete(UserChannel.t()) :: :ok
  def delete(user_channel) do
    Memento.Query.delete_record(user_channel)
  end

  @doc """
  Deletes all user_channels
  """
  @spec delete_all(list(UserChannel.t())) :: :ok
  def delete_all(user_channels) do
    Enum.each(user_channels, fn user_channel ->
      Memento.Query.delete_record(user_channel)
    end)

    :ok
  end

  @doc """
  Gets a user_channel for a user and channel
  """
  @spec get_by_user_and_channel(User.t(), Channel.t()) :: {:ok, UserChannel.t()} | {:error, String.t()}
  def get_by_user_and_channel(user, channel) do
    Memento.Query.select(UserChannel, [
      {:==, :user_socket, user.socket},
      {:==, :channel_name, channel.name}
    ])
    |> case do
      [%UserChannel{} = user_channel] -> {:ok, user_channel}
      [] -> {:error, "UserChannel not found"}
    end
  end

  @doc """
  Gets all user_channel for a user
  """
  @spec get_by_user_socket(port()) :: list(UserChannel.t())
  def get_by_user_socket(user_socket) do
    Memento.Query.select(UserChannel, {:==, :user_socket, user_socket})
  end

  @doc """
  Gets all user_channel for a channel
  """
  @spec get_by_channel_name(String.t()) :: list(UserChannel.t())
  def get_by_channel_name(channel_name) do
    Memento.Query.select(UserChannel, {:==, :channel_name, channel_name})
  end
end
