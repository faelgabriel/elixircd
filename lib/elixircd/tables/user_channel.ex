defmodule ElixIRCd.Tables.UserChannel do
  @moduledoc """
  Module for the UserChannel table.
  """

  @enforce_keys [:user_pid, :user_transport, :channel_name_key, :modes, :created_at]
  use Memento.Table,
    attributes: [
      :user_pid,
      :user_transport,
      :channel_name_key,
      :modes,
      :created_at
    ],
    index: [:channel_name_key],
    type: :bag

  @type t :: %__MODULE__{
          user_pid: pid(),
          user_transport: :tcp | :tls | :ws | :wss,
          channel_name_key: String.t(),
          modes: [String.t()],
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:user_pid) => pid(),
          optional(:user_transport) => :tcp | :tls | :ws | :wss,
          optional(:channel_name_key) => String.t(),
          optional(:modes) => [String.t()],
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new user channel.
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
  Update a user channel.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(user_channel, attrs) do
    struct!(user_channel, attrs)
  end
end
