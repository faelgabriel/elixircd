defmodule ElixIRCd.Repository.Channels do
  @moduledoc """
  Module for the channels repository.
  """

  alias ElixIRCd.Tables.Channel

  @doc """
  Create a new channel and write it to the database.
  """
  @spec create(map()) :: Channel.t()
  def create(attrs) do
    Channel.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Get a channel by the name.
  """
  @spec get_by_name(String.t()) :: {:ok, Channel.t()} | {:error, String.t()}
  def get_by_name(name) do
    Memento.Query.read(Channel, name)
    |> case do
      nil -> {:error, "Channel not found"}
      channel -> {:ok, channel}
    end
  end
end
