defmodule ElixIRCd.Tables.ChannelListTombstone do
  @moduledoc """
  Durable removal facts for channel list entries.

  The C2S tables are physical presence tables. ENP/1 also needs the removal
  stamp to survive a restart and to be included in a later complete snapshot.
  """

  @enforce_keys [:id, :channel_name_key, :mode, :mask, :set_by, :set_ms]
  alias ElixIRCd.Server.S2S.Identity

  use Memento.Table,
    attributes: [:id, :channel_name_key, :mode, :mask, :set_by, :set_ms, :stamp],
    index: [:channel_name_key],
    type: :set

  @type t :: %__MODULE__{
          id: {String.t(), String.t(), String.t()},
          channel_name_key: String.t(),
          mode: String.t(),
          mask: String.t(),
          set_by: String.t(),
          set_ms: non_neg_integer(),
          stamp: Identity.stamp() | nil
        }

  @type t_attrs :: %{
          required(:channel_name_key) => String.t(),
          required(:mode) => String.t(),
          required(:mask) => String.t(),
          required(:set_by) => String.t(),
          required(:set_ms) => non_neg_integer(),
          optional(:stamp) => Identity.stamp() | nil,
          optional(:id) => {String.t(), String.t(), String.t()}
        }

  @doc "Builds a tombstone for one channel list slot."
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    struct!(
      __MODULE__,
      Map.merge(attrs, %{
        id: {attrs.channel_name_key, attrs.mode, attrs.mask},
        set_ms: max(attrs.set_ms, 1),
        stamp: Map.get(attrs, :stamp)
      })
    )
  end
end
