defmodule ElixIRCd.Repositories.RegisteredChannels do
  @moduledoc """
  Repository module for managing registered channels in Mnesia database.
  """

  alias ElixIRCd.Tables.Channel.Topic
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

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
    :mnesia.index_read(RegisteredChannel, founder, :founder)
    |> Enum.map(&Data.load/1)
  end

  @doc """
  Get all registered channels where the given account is the successor.
  """
  @spec get_by_successor(String.t()) :: [RegisteredChannel.t()]
  def get_by_successor(successor) do
    :mnesia.index_read(RegisteredChannel, successor, :successor)
    |> Enum.map(&Data.load/1)
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
  Update a registered channel topic and its persistent topic snapshot.

  The structured topic is retained for INFO and metadata while the text
  snapshot is used when KEEPTOPIC recreates an empty channel.
  """
  @spec update_topic(RegisteredChannel.t(), Topic.t() | nil) :: RegisteredChannel.t()
  def update_topic(registered_channel, topic) do
    settings = RegisteredChannel.Settings.update(registered_channel.settings, %{persistent_topic: topic_text(topic)})

    update(registered_channel, %{topic: topic, settings: settings})
  end

  @doc """
  Delete a registered channel from the database.
  """
  @spec delete(RegisteredChannel.t()) :: :ok
  def delete(registered_channel) do
    Memento.Query.delete_record(registered_channel)
  end

  @spec topic_text(Topic.t() | nil) :: String.t() | nil
  defp topic_text(nil), do: nil
  defp topic_text(%Topic{text: text}), do: text
end
