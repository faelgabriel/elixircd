defmodule ElixIRCd.Tables.ClientBatch do
  @moduledoc "Ephemeral state for one client-originated multiline batch."

  @enforce_keys [:id, :user_pid, :reference, :target, :lines, :bytes, :invalid, :tags, :created_at]
  use Memento.Table,
    attributes: [:id, :user_pid, :reference, :target, :command, :lines, :bytes, :invalid, :tags, :created_at],
    index: [:user_pid],
    type: :set

  @type t :: %__MODULE__{
          id: {pid(), String.t()},
          user_pid: pid(),
          reference: String.t(),
          target: String.t(),
          command: String.t() | nil,
          lines: [ElixIRCd.Message.t()],
          bytes: non_neg_integer(),
          invalid: boolean(),
          tags: ElixIRCd.Message.tags(),
          created_at: DateTime.t()
        }

  @doc "Builds an ephemeral client batch with bounded-delivery defaults."
  @spec new(map()) :: t()
  def new(attrs) do
    attrs
    |> Map.put_new(:command, nil)
    |> Map.put_new(:lines, [])
    |> Map.put_new(:bytes, 0)
    |> Map.put_new(:invalid, false)
    |> Map.put_new(:tags, %{})
    |> Map.put_new(:created_at, DateTime.utc_now())
    |> then(&struct!(__MODULE__, &1))
  end
end
