defmodule ElixIRCd.Tables.ChannelBan do
  @moduledoc """
  Module for the ChannelBan table.
  """

  alias ElixIRCd.Utils.Protocol

  @enforce_keys [:channel_name_key, :mask, :mask_key, :setter, :created_at]
  use Memento.Table,
    attributes: [
      :channel_name_key,
      :mask,
      :mask_key,
      :setter,
      :created_at
    ],
    index: [],
    type: :bag

  @type t :: %__MODULE__{
          channel_name_key: String.t(),
          mask: String.t(),
          mask_key: String.t(),
          setter: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:channel_name_key) => String.t(),
          optional(:mask) => String.t(),
          optional(:mask_key) => String.t(),
          optional(:setter) => String.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new channel ban.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put(:mask_key, Protocol.mask_key(Map.fetch!(attrs, :mask)))
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
