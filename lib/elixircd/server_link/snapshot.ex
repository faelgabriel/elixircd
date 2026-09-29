defmodule ElixIRCd.ServerLink.Snapshot do
  @moduledoc "One origin's committed, PID-free state prepared for a server-link burst."

  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.UserPayload

  @enforce_keys [:origin, :epoch, :cursor, :users]
  defstruct [:origin, :epoch, :cursor, :users, channels: [], members: [], lists: [], invites: []]

  @type t :: %__MODULE__{
          origin: String.t(),
          epoch: String.t(),
          cursor: non_neg_integer(),
          users: [UserPayload.wire_user()],
          channels: [map()],
          members: [map()],
          lists: [map()],
          invites: [map()]
        }

  @doc "Rejects a burst that cannot fit the protocol's record and origin budgets."
  @spec validate(t(), pos_integer()) :: :ok | {:error, :local_snapshot_too_large}
  def validate(%__MODULE__{} = snapshot, max_bytes) do
    [snapshot.users, snapshot.channels, snapshot.members, snapshot.lists, snapshot.invites]
    |> Stream.concat()
    |> Enum.reduce_while({0, 0}, fn record, {count, bytes} ->
      next_count = count + 1
      next_bytes = bytes + :erlang.external_size(record)

      if next_count > Frame.max_snapshot_entries() or next_bytes > max_bytes,
        do: {:halt, {:error, :local_snapshot_too_large}},
        else: {:cont, {next_count, next_bytes}}
    end)
    |> case do
      {:error, :local_snapshot_too_large} = error -> error
      {_count, _bytes} -> :ok
    end
  end
end
