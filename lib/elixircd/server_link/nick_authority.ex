defmodule ElixIRCd.ServerLink.NickAuthority do
  @moduledoc "Orders simultaneous nickname claims consistently on every server."

  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @enforce_keys [:origin, :uid, :nick_key, :registered_at]
  defstruct [:origin, :uid, :nick_key, :registered_at]

  @type t :: %__MODULE__{
          origin: String.t(),
          uid: String.t() | nil,
          nick_key: String.t(),
          registered_at: DateTime.t()
        }

  @doc "Converts a validated network user into a typed nickname claim."
  @spec from_wire(String.t(), map()) :: t()
  def from_wire(origin, %{"uid" => uid, "nick" => nick, "registered_at" => registered_at}) do
    {:ok, timestamp, _offset} = DateTime.from_iso8601(registered_at)

    %__MODULE__{
      origin: origin,
      uid: uid,
      nick_key: CaseMapping.normalize(nick),
      registered_at: timestamp
    }
  end

  @doc "Converts a registered local user into a typed nickname claim."
  @spec from_local(String.t(), User.t()) :: t()
  def from_local(origin, %User{} = user) do
    %__MODULE__{
      origin: origin,
      uid: nil,
      nick_key: user.nick_key,
      registered_at: user.registered_at || user.created_at
    }
  end

  @doc "Ranks the oldest registration first, then the home server and UID."
  @spec rank(t()) :: {integer(), String.t(), String.t()}
  def rank(%__MODULE__{} = claim) do
    {DateTime.to_unix(claim.registered_at, :microsecond), claim.origin, claim.uid || ""}
  end
end
