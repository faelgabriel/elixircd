defmodule ElixIRCd.Tables.RegisteredChannel do
  @moduledoc """
  Module for the RegisteredChannel table.
  """

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel.Settings
  alias ElixIRCd.Utils.CaseMapping

  @enforce_keys [:name_key, :name, :founder, :password_hash, :registered_by, :created_at]

  use Memento.Table,
    attributes: [
      :name_key,
      :name,
      :founder,
      :password_hash,
      :registered_by,
      :settings,
      :topic,
      :successor,
      :last_used_at,
      :created_at
    ],
    index: [:founder],
    type: :set

  @type t :: %__MODULE__{
          name_key: String.t(),
          name: String.t(),
          founder: String.t(),
          password_hash: String.t(),
          registered_by: String.t(),
          settings: Settings.t(),
          topic: Channel.Topic.t() | nil,
          successor: String.t() | nil,
          last_used_at: DateTime.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:name) => String.t(),
          optional(:founder) => String.t(),
          optional(:password_hash) => String.t(),
          optional(:registered_by) => String.t(),
          optional(:settings) => Settings.t(),
          optional(:topic) => Channel.Topic.t() | nil,
          optional(:successor) => String.t() | nil,
          optional(:last_used_at) => DateTime.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new registered channel.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    new_attrs =
      attrs
      |> Map.put_new(:settings, Settings.new())
      |> Map.put_new(:topic, nil)
      |> Map.put_new(:successor, nil)
      |> Map.put_new(:last_used_at, now)
      |> Map.put_new(:created_at, now)
      |> handle_name_key()

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a registered channel.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(registered_channel, attrs) do
    new_attrs =
      attrs
      |> handle_name_key()

    struct!(registered_channel, new_attrs)
  end

  @spec handle_name_key(t_attrs()) :: t_attrs()
  defp handle_name_key(%{name: name} = attrs) do
    name_key = if name != nil, do: CaseMapping.normalize(name), else: nil
    Map.put(attrs, :name_key, name_key)
  end

  defp handle_name_key(attrs), do: attrs
end
