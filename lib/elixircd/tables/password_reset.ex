defmodule ElixIRCd.Tables.PasswordReset do
  @moduledoc "Persistent, single-use NickServ password reset challenge."

  alias ElixIRCd.Utils.CaseMapping

  @enforce_keys [:account_name_key, :code_hash, :requested_at, :expires_at]
  use Memento.Table,
    attributes: [:account_name_key, :code_hash, :requested_at, :expires_at],
    type: :set

  @type t :: %__MODULE__{
          account_name_key: String.t(),
          code_hash: binary(),
          requested_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  @doc "Builds a reset challenge with a normalized account key."
  @spec new(String.t(), binary(), DateTime.t(), DateTime.t()) :: t()
  def new(account_name, code_hash, requested_at, expires_at) do
    %__MODULE__{
      account_name_key: CaseMapping.normalize(account_name),
      code_hash: code_hash,
      requested_at: requested_at,
      expires_at: expires_at
    }
  end
end
