defmodule ElixIRCd.ServerLink.Directory do
  @moduledoc "Read-only, PID-free remote nickname index for local IRC command checks."

  alias ElixIRCd.ServerLink.RemoteUser
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.Utils.CaseMapping

  @table :elixircd_server_link_directory

  @doc "Creates the index owned by the production link coordinator."
  @spec create() :: :ets.tid()
  def create do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
  end

  @doc "Reads a committed remote user without asking a GenServer inside an IRC transaction."
  @spec get_by_nick(String.t()) :: {:ok, RemoteUser.t()} | :error
  def get_by_nick(nick) do
    case lookup_by_nick(nick) do
      :unavailable -> :error
      result -> result
    end
  end

  @doc "Reads a remote nickname while preserving index loss as a distinct result."
  @spec lookup_by_nick(String.t()) :: {:ok, RemoteUser.t()} | :error | :unavailable
  def lookup_by_nick(nick) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, CaseMapping.normalize(nick)) do
        [{_key, origin, uid, user}] -> {:ok, %RemoteUser{origin: origin, uid: uid, user: user}}
        [] -> :error
      end
    else
      :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc "Reads one selected remote user by its authenticated home and stable UID."
  @spec get_by_identity(String.t(), String.t()) :: {:ok, RemoteUser.t()} | :error
  def get_by_identity(origin, uid) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, {:uid, origin, uid}) do
        [{_key, ^origin, ^uid, user}] -> {:ok, %RemoteUser{origin: origin, uid: uid, user: user}}
        [] -> :error
      end
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Lists committed remote users for network-wide queries."
  @spec all() :: [RemoteUser.t()] | :unavailable
  def all do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table)
      |> Enum.flat_map(fn
        {nick_key, origin, uid, user} when is_binary(nick_key) -> [%RemoteUser{origin: origin, uid: uid, user: user}]
        _identity_entry -> []
      end)
    else
      :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc "Publishes committed nickname changes from the owning coordinator."
  @spec sync(:ets.tid() | nil, Replica.t(), Replica.t()) :: :ok
  def sync(nil, _old, _current), do: :ok

  def sync(table, old, current) do
    if old.users != current.users or old.nick_keys != current.nick_keys do
      for {nick_key, _identity} <- old.nick_keys, not Map.has_key?(current.nick_keys, nick_key) do
        :ets.delete(table, nick_key)
      end

      old_identities = old.nick_keys |> Map.values() |> MapSet.new()
      new_identities = current.nick_keys |> Map.values() |> MapSet.new()

      for {origin, uid} <- MapSet.difference(old_identities, new_identities) do
        :ets.delete(table, {:uid, origin, uid})
      end

      for {nick_key, {origin, uid} = identity} <- current.nick_keys do
        user = Map.fetch!(current.users, identity)
        :ets.insert(table, {nick_key, origin, uid, user})
        :ets.insert(table, {{:uid, origin, uid}, origin, uid, user})
      end
    end

    :ok
  end
end
