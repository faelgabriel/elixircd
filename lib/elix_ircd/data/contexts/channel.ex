defmodule ElixIRCd.Contexts.Channel do
  @moduledoc """
  Module for the Channel contexts.
  """

  alias ElixIRCd.Data.Tables.Channel

  require Logger

  @doc """
  Creates a new channel
  """
  @spec create(map()) :: {:ok, Channel.t()} | {:error, String.t()}
  def create(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Memento.Query.write()
    |> case do
      %Channel{} = channel -> {:ok, channel}
      error -> {:error, "Channel not created: #{error}"}
    end
  end

  @doc """
  Updates a channel
  """
  @spec update(Channel.t(), map()) :: {:ok, Channel.t()} | {:error, String.t()}
  def update(channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Memento.Query.write()
    |> case do
      %Channel{} = channel -> {:ok, channel}
      error -> {:error, "Channel not updated: #{error}"}
    end
  end

  @doc """
  Deletes a channel
  """
  @spec delete(Channel.t()) :: :ok
  def delete(channel) do
    Memento.Query.delete(Channel, channel.name)
  end

  @doc """
  Gets a channel by name
  """
  @spec get_by_name(String.t()) :: {:ok, Channel.t()} | {:error, String.t()}
  def get_by_name(name) do
    Memento.Query.read(Channel, name)
    |> case do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, "Channel not found"}
    end
  end
end
