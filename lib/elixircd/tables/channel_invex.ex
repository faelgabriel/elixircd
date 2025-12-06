defmodule ElixIRCd.Tables.ChannelInvex do
  @moduledoc """
  Module for the ChannelInvex table.

  This table stores invite exceptions (+I mode) for channels.
  Users matching an invex mask can join invite-only channels without an invite.
  """

  @enforce_keys [:channel_name_key, :mask, :setter, :created_at]
  use Memento.Table,
    attributes: [
      :channel_name_key,
      :mask,
      :setter,
      :created_at
    ],
    index: [],
    type: :bag

  @type t :: %__MODULE__{
          channel_name_key: String.t(),
          mask: String.t(),
          setter: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:channel_name_key) => String.t(),
          optional(:mask) => String.t(),
          optional(:setter) => String.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new channel invex.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
