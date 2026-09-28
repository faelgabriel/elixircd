defmodule ElixIRCd.Tables.RegisteredChannelAkick do
  @moduledoc "Persistent ChanServ auto-kick entry for an account or hostmask."

  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  @enforce_keys [:id, :channel_name_key, :kind, :target_key, :target, :setter, :created_at]
  use Memento.Table,
    attributes: [:id, :channel_name_key, :kind, :target_key, :target, :reason, :setter, :created_at],
    index: [:channel_name_key, :target_key],
    type: :set

  @type t :: %__MODULE__{
          id: {String.t(), :account | :mask, String.t()},
          channel_name_key: String.t(),
          kind: :account | :mask,
          target_key: String.t(),
          target: String.t(),
          reason: String.t() | nil,
          setter: String.t(),
          created_at: DateTime.t()
        }

  @doc "Builds an auto-kick entry with normalized channel and target keys."
  @spec new(String.t(), :account | :mask, String.t(), String.t() | nil, String.t()) :: t()
  def new(channel_name, kind, target, reason, setter) do
    channel_key = CaseMapping.normalize(channel_name)
    target_key = if kind == :account, do: CaseMapping.normalize(target), else: Protocol.mask_key(target)

    %__MODULE__{
      id: {channel_key, kind, target_key},
      channel_name_key: channel_key,
      kind: kind,
      target_key: target_key,
      target: target,
      reason: reason,
      setter: setter,
      created_at: DateTime.utc_now()
    }
  end
end
