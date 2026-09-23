defmodule ElixIRCd.Tables.ChannelExcept do
  @moduledoc """
  Module for the ChannelExcept table.

  This table stores ban exceptions (+e mode) for channels.
  Users matching an except mask are allowed to join even if they match a ban.
  """

  @enforce_keys [:channel_name_key, :mask, :setter, :created_at]
  alias ElixIRCd.Server.S2S.Identity

  use Memento.Table,
    attributes: [
      :channel_name_key,
      :mask,
      :setter,
      :created_at,
      :stamp
    ],
    index: [],
    type: :bag

  @type t :: %__MODULE__{
          channel_name_key: String.t(),
          mask: String.t(),
          setter: String.t(),
          created_at: DateTime.t(),
          stamp: Identity.stamp() | nil
        }

  @type t_attrs :: %{
          optional(:channel_name_key) => String.t(),
          optional(:mask) => String.t(),
          optional(:setter) => String.t(),
          optional(:created_at) => DateTime.t(),
          optional(:stamp) => Identity.stamp() | nil
        }

  @doc """
  Create a new channel except.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:created_at, DateTime.utc_now())
      |> Map.put_new(:stamp, nil)

    struct!(__MODULE__, new_attrs)
  end
end
