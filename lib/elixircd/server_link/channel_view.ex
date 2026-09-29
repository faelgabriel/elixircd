defmodule ElixIRCd.ServerLink.ChannelView do
  @moduledoc "Builds a committed, PID-free channel view for IRC transactions."

  alias ElixIRCd.ServerLink.ChannelAuthority
  alias ElixIRCd.ServerLink.Replica

  defmodule RemoteMember do
    @moduledoc "One remote member with status qualified by the selected channel identity."

    @enforce_keys [:origin, :member, :user, :effective_modes]
    defstruct [:origin, :member, :user, :effective_modes, effective: true]

    @type t :: %__MODULE__{
            origin: String.t(),
            member: map(),
            user: map(),
            effective_modes: [String.t()],
            effective: boolean()
          }
  end

  defmodule RemoteRecord do
    @moduledoc "One remote list or invite record qualified by the selected channel identity."

    @enforce_keys [:origin, :entry, :effective]
    defstruct [:origin, :entry, :effective]

    @type t :: %__MODULE__{origin: String.t(), entry: map(), effective: boolean()}
  end

  @enforce_keys [:origin, :channel, :remote_present]
  defstruct [:origin, :channel, :remote_present, remote_members: [], remote_lists: [], remote_invites: []]

  @type t :: %__MODULE__{
          origin: String.t(),
          channel: map(),
          remote_present: boolean(),
          remote_members: [RemoteMember.t()],
          remote_lists: [RemoteRecord.t()],
          remote_invites: [RemoteRecord.t()]
        }

  @doc "Combines selected metadata with remote records already committed in the replica."
  @spec build(ChannelAuthority.selected(), Replica.t()) :: %{String.t() => t()}
  def build(authorities, replica) do
    members = group_members(replica, authorities)
    lists = group_records(replica.lists, replica.channels, authorities)
    invites = group_records(replica.invites, replica.channels, authorities)

    Map.new(authorities, fn {key, winner} ->
      {key,
       %__MODULE__{
         origin: winner.origin,
         channel: winner.channel,
         remote_present: winner.remote_present,
         remote_members: Map.get(members, key, []),
         remote_lists: Map.get(lists, key, []),
         remote_invites: Map.get(invites, key, [])
       }}
    end)
  end

  @doc "Selects the metadata authority and builds its committed read view."
  @spec select(String.t(), %{optional(String.t()) => map()}, Replica.t()) :: %{String.t() => t()}
  def select(local_origin, local_channels, replica) do
    local_origin
    |> ChannelAuthority.select(local_channels, replica.channels)
    |> build(replica)
  end

  defp group_members(replica, authorities) do
    replica.members
    |> Enum.flat_map(&project_member(&1, replica, authorities))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, entries} -> {key, Enum.sort_by(entries, &{&1.origin, &1.member["uid"]})} end)
  end

  defp project_member({{origin, {channel_key, uid}}, member}, replica, authorities) do
    case {Map.fetch(replica.users, {origin, uid}), Map.fetch(authorities, channel_key)} do
      {{:ok, user}, {:ok, authority}} ->
        contributed_channel = Map.fetch!(replica.channels, {origin, channel_key})
        effective = same_identity?(contributed_channel, authority.channel)
        effective_modes = if effective, do: member["modes"], else: []

        [
          {channel_key,
           %RemoteMember{
             origin: origin,
             member: member,
             user: user,
             effective_modes: effective_modes,
             effective: effective
           }}
        ]

      _ ->
        []
    end
  end

  defp same_identity?(left, right) do
    {:ok, left_time, _} = DateTime.from_iso8601(left["created_at"])
    {:ok, right_time, _} = DateTime.from_iso8601(right["created_at"])
    left["creator"] == right["creator"] and DateTime.compare(left_time, right_time) == :eq
  end

  defp group_records(records, channels, authorities) do
    records
    |> Enum.map(fn {{origin, entry_key}, entry} ->
      channel_key = elem(entry_key, 0)
      contributor = Map.fetch!(channels, {origin, channel_key})
      authority = Map.fetch!(authorities, channel_key)
      effective? = same_identity?(contributor, authority.channel)
      {channel_key, %RemoteRecord{origin: origin, entry: entry, effective: effective?}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, entries} -> {key, Enum.sort_by(entries, &{&1.origin, Jason.encode!(&1.entry)})} end)
  end
end
