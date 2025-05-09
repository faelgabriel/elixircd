defmodule ElixIRCd.Tables.Channel do
  @moduledoc """
  Module for the Channel table.
  """

  @enforce_keys [:name, :modes, :created_at]
  use Memento.Table,
    attributes: [
      :name,
      :topic,
      :modes,
      :created_at
    ],
    index: [],
    type: :set

  alias ElixIRCd.Tables.Channel

  @type t :: %__MODULE__{
          name: String.t(),
          topic: Channel.Topic.t() | nil,
          modes: [String.t() | {String.t(), String.t()}],
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:name) => String.t(),
          optional(:topic) => Channel.Topic.t() | nil,
          optional(:modes) => [String.t() | {String.t(), String.t()}],
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new channel.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:modes, [])
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a channel.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(channel, attrs) do
    struct!(channel, attrs)
  end
end
