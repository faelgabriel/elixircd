defmodule ElixIRCd.Tables.UserAcceptRemote do
  @moduledoc "A local client's permission for one authenticated remote user UID."

  @enforce_keys [:user_pid, :accepted_identity, :created_at]
  use Memento.Table,
    attributes: [:user_pid, :accepted_identity, :created_at],
    index: [:accepted_identity],
    type: :bag

  @type identity :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          user_pid: pid(),
          accepted_identity: identity(),
          created_at: DateTime.t()
        }

  @doc "Builds a typed permission for a remote user's home server and UID."
  @spec new(pid(), identity()) :: t()
  def new(user_pid, {origin, uid} = identity) when is_pid(user_pid) and is_binary(origin) and is_binary(uid) do
    %__MODULE__{user_pid: user_pid, accepted_identity: identity, created_at: DateTime.utc_now()}
  end
end
