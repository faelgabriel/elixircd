defmodule ElixIRCd.Repositories.RegisteredChannels do
  @moduledoc """
  Repository module for managing registered channels in Mnesia database.
  """

  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Create a new registered channel and write it to the database.
  """
  @spec create(map()) :: RegisteredChannel.t()
  def create(params) do
    RegisteredChannel.new(params)
    |> Memento.Query.write()
  end

  @doc """
  Get a registered channel by its name.
  """
  @spec get_by_name(String.t()) :: {:ok, RegisteredChannel.t()} | {:error, :registered_channel_not_found}
  def get_by_name(name) do
    name_key = CaseMapping.normalize(name)

    Memento.Query.read(RegisteredChannel, name_key)
    |> case do
      nil -> {:error, :registered_channel_not_found}
      registered_channel -> {:ok, registered_channel}
    end
  end

  @doc """
  Get all registered channels.
  """
  @spec get_all() :: [RegisteredChannel.t()]
  def get_all do
    Memento.Query.all(RegisteredChannel)
  end

  @doc """
  Get all registered channels where the given user is the founder.
  """
  @spec get_by_founder(String.t()) :: [RegisteredChannel.t()]
  def get_by_founder(founder) do
    Memento.Query.select(RegisteredChannel, {:==, :founder, founder})
  end

  @doc """
  Update a registered channel in the database.
  """
  @spec update(RegisteredChannel.t(), map()) :: RegisteredChannel.t()
  def update(registered_channel, attrs) do
    RegisteredChannel.update(registered_channel, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a registered channel from the database.
  """
  @spec delete(RegisteredChannel.t()) :: :ok
  def delete(registered_channel) do
    Memento.Query.delete_record(registered_channel)
  end
end
