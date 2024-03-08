defmodule ElixIRCd.Tables.ChannelBan do
  @moduledoc """
  Module for the ChannelBan table.
  """

  @enforce_keys [:channel_name, :mask, :setter, :created_at]
  use Memento.Table,
    attributes: [
      :channel_name,
      :mask,
      :setter,
      :created_at
    ],
    index: [],
    type: :bag

  @type t :: %__MODULE__{
          channel_name: String.t(),
          mask: String.t(),
          setter: String.t(),
          created_at: DateTime.t()
        }

  @doc """
  Create a new channel ban.
  """
  @spec new(map()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
