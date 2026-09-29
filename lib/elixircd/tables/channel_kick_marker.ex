defmodule ElixIRCd.Tables.ChannelKickMarker do
  @moduledoc "Keeps the committed cause of a local membership removal until the projector emits its delta."

  @enforce_keys [:key, :actor_pid, :actor_origin, :actor_mask, :reason, :created_at]
  use Memento.Table,
    attributes: [:key, :actor_pid, :actor_origin, :actor_uid, :actor_mask, :reason, :created_at],
    index: [],
    type: :set

  @type key :: {String.t(), pid(), String.t()}
  @type t :: %__MODULE__{
          key: key(),
          actor_pid: pid() | nil,
          actor_origin: String.t(),
          actor_uid: String.t() | nil,
          actor_mask: String.t(),
          reason: String.t(),
          created_at: DateTime.t()
        }

  @doc "Builds a marker for a committed local KICK."
  @spec local(String.t(), pid(), DateTime.t(), pid(), String.t(), String.t(), String.t()) :: t()
  def local(channel_key, target_pid, joined_at, actor_pid, origin, actor_mask, reason) do
    %__MODULE__{
      key: {channel_key, target_pid, DateTime.to_iso8601(joined_at)},
      actor_pid: actor_pid,
      actor_origin: origin,
      actor_uid: nil,
      actor_mask: actor_mask,
      reason: reason,
      created_at: DateTime.utc_now()
    }
  end
end
