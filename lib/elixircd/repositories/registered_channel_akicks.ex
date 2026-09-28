defmodule ElixIRCd.Repositories.RegisteredChannelAkicks do
  @moduledoc "Repository for persistent ChanServ auto-kick entries."

  alias ElixIRCd.Tables.RegisteredChannelAkick
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol
  alias Memento.Query.Data

  @doc "Lists the auto-kick entries for a channel."
  @spec list(String.t()) :: [RegisteredChannelAkick.t()]
  def list(channel_name) do
    key = CaseMapping.normalize(channel_name)

    :mnesia.index_read(RegisteredChannelAkick, key, :channel_name_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(&{&1.kind, &1.target_key})
  end

  @doc "Reads a channel auto-kick entry by kind and target."
  @spec get(String.t(), :account | :mask, String.t()) :: RegisteredChannelAkick.t() | nil
  def get(channel_name, kind, target) do
    key = if kind == :account, do: CaseMapping.normalize(target), else: Protocol.mask_key(target)
    Memento.Query.read(RegisteredChannelAkick, {CaseMapping.normalize(channel_name), kind, key})
  end

  @doc "Stores a channel auto-kick entry."
  @spec put(RegisteredChannelAkick.t()) :: RegisteredChannelAkick.t()
  def put(entry), do: Memento.Query.write(entry)

  @doc "Deletes a channel auto-kick entry."
  @spec delete(RegisteredChannelAkick.t()) :: :ok
  def delete(entry), do: Memento.Query.delete_record(entry)

  @doc "Deletes all auto-kick entries for a channel."
  @spec delete_by_channel(String.t()) :: :ok
  def delete_by_channel(channel_name) do
    channel_name |> list() |> Enum.each(&delete/1)
    :ok
  end

  @doc "Deletes account entries when a NickServ account is removed."
  @spec delete_by_account(String.t()) :: :ok
  def delete_by_account(account_name) do
    key = CaseMapping.normalize(account_name)

    :mnesia.index_read(RegisteredChannelAkick, key, :target_key)
    |> Enum.map(&Data.load/1)
    |> Enum.filter(&(&1.kind == :account))
    |> Enum.each(&delete/1)

    :ok
  end

  @doc "Moves all auto-kick entries when a channel is renamed."
  @spec rename(String.t(), String.t()) :: :ok
  def rename(old_name, new_name) do
    new_key = CaseMapping.normalize(new_name)

    old_name
    |> list()
    |> Enum.each(fn entry ->
      delete(entry)
      put(%{entry | id: {new_key, entry.kind, entry.target_key}, channel_name_key: new_key})
    end)

    :ok
  end
end
