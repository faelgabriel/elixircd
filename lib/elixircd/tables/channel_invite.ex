defmodule ElixIRCd.Tables.ChannelInvite do
  @moduledoc """
  Module for the ChannelInvite table.
  """

  @enforce_keys [:channel_name, :user_port, :setter, :created_at]
  use Memento.Table,
    attributes: [
      :channel_name,
      :user_port,
      :setter,
      :created_at
    ],
    index: [],
    type: :bag

  @type t :: %__MODULE__{
          channel_name: String.t(),
          user_port: port(),
          setter: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:channel_name) => String.t(),
          optional(:user_port) => port(),
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
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
