defmodule ElixIRCd.Tables.MetadataSubscription do
  @moduledoc "Per-connection IRCv3 metadata subscription."

  use Memento.Table,
    attributes: [:id, :user_pid, :key],
    index: [:user_pid, :key],
    type: :set

  @type t :: %__MODULE__{id: {pid(), String.t()}, user_pid: pid(), key: String.t()}

  @doc "Builds a metadata subscription for a connection and key."
  @spec new(pid(), String.t()) :: t()
  def new(user_pid, key), do: %__MODULE__{id: {user_pid, key}, user_pid: user_pid, key: key}
end
