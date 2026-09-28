defmodule ElixIRCd.Tables.Operator do
  @moduledoc "Persistent credentials for IRC operators managed outside the configuration file."

  @enforce_keys [:name, :password_hash, :created_at, :updated_at]
  use Memento.Table,
    attributes: [:name, :password_hash, :enabled, :created_at, :updated_at],
    type: :set

  @type t :: %__MODULE__{
          name: String.t(),
          password_hash: String.t(),
          enabled: boolean(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
