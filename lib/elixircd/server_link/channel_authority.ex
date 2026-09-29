defmodule ElixIRCd.ServerLink.ChannelAuthority do
  @moduledoc "Selects one deterministic metadata authority for each network channel."

  alias ElixIRCd.Utils.CaseMapping

  defmodule Winner do
    @moduledoc "Selected metadata contributor and whether any remote contributor is present."

    @enforce_keys [:origin, :channel]
    defstruct [:origin, :channel, remote_present: false]

    @type t :: %__MODULE__{origin: String.t(), channel: map(), remote_present: boolean()}
  end

  @type winner :: Winner.t()
  @type selected :: %{optional(String.t()) => winner()}

  @doc "Chooses the oldest creation timestamp, then creation server, then active contributor."
  @spec select(String.t(), %{optional(String.t()) => map()}, %{optional({String.t(), String.t()}) => map()}) ::
          selected()
  def select(local_origin, local_channels, remote_channels) do
    local = Enum.map(local_channels, fn {key, channel} -> {key, %Winner{origin: local_origin, channel: channel}} end)

    remote =
      Enum.map(remote_channels, fn {{origin, key}, channel} ->
        {key, %Winner{origin: origin, channel: channel}}
      end)

    remote_keys = remote_channels |> Map.keys() |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    (local ++ remote)
    |> Enum.reduce(%{}, fn {key, candidate}, selected ->
      Map.update(selected, key, candidate, &older(&1, candidate))
    end)
    |> Map.new(fn {key, winner} -> {key, %{winner | remote_present: MapSet.member?(remote_keys, key)}} end)
  end

  @doc "Finds the selected metadata authority by IRC channel name."
  @spec get(selected(), String.t()) :: {:ok, winner()} | :error
  def get(selected, name), do: Map.fetch(selected, CaseMapping.normalize(name))

  defp older(current, candidate) do
    if rank(candidate) < rank(current), do: candidate, else: current
  end

  defp rank(%Winner{origin: origin, channel: channel}) do
    {:ok, created_at, _offset} = DateTime.from_iso8601(channel["created_at"])
    creator = channel["creator"]
    creator_preference = if origin == creator, do: 0, else: 1
    {DateTime.to_unix(created_at, :microsecond), creator, creator_preference, origin}
  end
end
