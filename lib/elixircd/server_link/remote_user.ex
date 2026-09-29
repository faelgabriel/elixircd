defmodule ElixIRCd.ServerLink.RemoteUser do
  @moduledoc "A committed remote user and its authenticated home identity."

  @enforce_keys [:origin, :uid, :user]
  defstruct [:origin, :uid, :user]

  @type t :: %__MODULE__{
          origin: String.t(),
          uid: String.t(),
          user: ElixIRCd.ServerLink.UserPayload.wire_user()
        }
end
