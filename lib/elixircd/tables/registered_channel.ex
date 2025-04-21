defmodule ElixIRCd.Tables.RegisteredChannel do
  @moduledoc """
  Module for the RegisteredChannel table.
  """

  alias ElixIRCd.Tables.RegisteredChannel.Settings

  @enforce_keys [:name, :founder, :password_hash, :registered_by, :created_at]

  use Memento.Table,
    attributes: [
      :name,
      :founder,
      :password_hash,
      :registered_by,
      :settings,
      :created_at
    ],
    index: [:founder],
    type: :set

  @type t :: %__MODULE__{
          name: String.t(),
          founder: String.t(),
          password_hash: String.t(),
          registered_by: String.t(),
          settings: Settings.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:name) => String.t(),
          optional(:founder) => String.t(),
          optional(:password_hash) => String.t(),
          optional(:registered_by) => String.t(),
          optional(:settings) => Settings.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new registered channel.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:settings, Settings.new())
      |> Map.put_new(:created_at, DateTime.utc_now() |> DateTime.truncate(:second))

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a registered channel.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(registered_channel, attrs) do
    struct!(registered_channel, attrs)
  end
end
