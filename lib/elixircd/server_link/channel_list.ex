defmodule ElixIRCd.ServerLink.ChannelList do
  @moduledoc "Builds a typed, identity-fenced view of a channel list mode."

  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Utils.Protocol

  defmodule Entry do
    @moduledoc "A visible ban, exception or invite exception."

    @enforce_keys [:mask, :setter, :set_at]
    defstruct [:mask, :setter, :set_at]

    @type t :: %__MODULE__{mask: String.t(), setter: String.t(), set_at: DateTime.t()}
  end

  @type kind :: :b | :e | :I

  @doc "Reads local and committed remote contributions that match the selected channel creation."
  @spec read(Channel.t(), kind()) :: {:ok, [Entry.t()]} | {:error, :network_directory_unavailable}
  def read(%Channel{} = channel, kind) when kind in [:b, :e, :I] do
    local = local_entries(channel, kind)
    links_enabled? = Application.fetch_env!(:elixircd, :server_links)[:enabled]

    case ChannelDirectory.get(channel.name) do
      {:ok, %ChannelView{} = view} ->
        visible_local = if same_identity?(channel, view), do: local, else: []
        {:ok, merge_entries(visible_local, remote_entries(view, kind))}

      :unavailable when links_enabled? ->
        {:error, :network_directory_unavailable}

      :error when links_enabled? ->
        {:error, :network_directory_unavailable}

      _ ->
        {:ok, local}
    end
  end

  defp local_entries(channel, kind) do
    records =
      case kind do
        :b -> ChannelBans.get_by_channel_name_key(channel.name_key)
        :e -> ChannelExcepts.get_by_channel_name_key(channel.name_key)
        :I -> ChannelInvexes.get_by_channel_name_key(channel.name_key)
      end

    Enum.map(records, fn record -> %Entry{mask: record.mask, setter: record.setter, set_at: record.created_at} end)
  end

  defp remote_entries(view, kind) do
    mode = Atom.to_string(kind)

    for %{effective: true, entry: %{"kind" => ^mode} = record} <- view.remote_lists,
        {:ok, set_at, _offset} <- [DateTime.from_iso8601(record["set_at"])] do
      %Entry{mask: record["mask"], setter: record["setter"], set_at: set_at}
    end
  end

  defp same_identity?(channel, view) do
    local_id = Application.fetch_env!(:elixircd, :server)[:hostname]

    creator =
      case Memento.Query.read(ChannelIdentity, channel.name_key) do
        %ChannelIdentity{creator: creator} -> creator
        nil -> local_id
      end

    case DateTime.from_iso8601(view.channel["created_at"]) do
      {:ok, created_at, _offset} ->
        creator == view.channel["creator"] and DateTime.compare(channel.created_at, created_at) == :eq

      _ ->
        false
    end
  end

  defp merge_entries(local, remote) do
    (local ++ remote)
    |> Enum.sort_by(fn entry ->
      {DateTime.to_unix(entry.set_at, :microsecond), Protocol.mask_key(entry.mask), entry.setter, entry.mask}
    end)
    |> Enum.uniq_by(&Protocol.mask_key(&1.mask))
  end
end
