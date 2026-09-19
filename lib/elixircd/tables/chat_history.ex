defmodule ElixIRCd.Tables.ChatHistory do
  @moduledoc "Persistent IRC message and event history entry."

  @enforce_keys [:id, :target_type, :target_key, :target_name, :msgid, :message, :occurred_at]
  use Memento.Table,
    attributes: [
      :id,
      :target_type,
      :target_key,
      :target_name,
      :msgid,
      :sender_account_key,
      :recipient_account_key,
      :message,
      :occurred_at,
      :redacted_at
    ],
    index: [:target_key, :msgid],
    type: :ordered_set

  @type t :: %__MODULE__{
          id: {String.t(), integer(), String.t()},
          target_type: :channel | :direct,
          target_key: String.t(),
          target_name: String.t(),
          msgid: String.t(),
          sender_account_key: String.t() | nil,
          recipient_account_key: String.t() | nil,
          message: ElixIRCd.Message.t(),
          occurred_at: DateTime.t(),
          redacted_at: DateTime.t() | nil
        }

  @doc "Builds a validated history record and defaults its redaction time to nil."
  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, Map.put_new(attrs, :redacted_at, nil))
end
