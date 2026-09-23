defmodule ElixIRCd.Tables.ChannelInvite do
  @moduledoc """
  Module for the ChannelInvite table.
  """

  alias ElixIRCd.Server.S2S.Identity

  @enforce_keys [:user_pid, :channel_name_key, :setter, :created_at]
  use Memento.Table,
    attributes: [
      :user_pid,
      :channel_name_key,
      :invite_id,
      :expires_ms,
      :setter,
      :created_at
    ],
    index: [],
    type: :bag

  @type t :: %__MODULE__{
          user_pid: pid(),
          channel_name_key: String.t(),
          invite_id: Identity.id(),
          expires_ms: non_neg_integer(),
          setter: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:user_pid) => pid(),
          optional(:channel_name_key) => String.t(),
          optional(:invite_id) => Identity.id(),
          optional(:expires_ms) => non_neg_integer(),
          optional(:setter) => String.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new channel invite.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:invite_id, Identity.nonce())
      |> Map.put_new(:expires_ms, 0)
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
