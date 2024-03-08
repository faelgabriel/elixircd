defmodule ElixIRCd.Tables.UserChannel do
  @moduledoc """
  Module for the UserChannel table.
  """

  @enforce_keys [:user_port, :user_socket, :user_transport, :channel_name, :modes, :created_at]
  use Memento.Table,
    attributes: [
      :user_port,
      :user_socket,
      :user_transport,
      :channel_name,
      :modes,
      :created_at
    ],
    index: [:channel_name],
    type: :bag

  @type t :: %__MODULE__{
          user_port: port(),
          user_socket: :inet.socket(),
          user_transport: :ranch_tcp | :ranch_ssl,
          channel_name: String.t(),
          modes: [String.t()],
          created_at: DateTime.t()
        }

  @doc """
  Create a new user channel.
  """
  @spec new(map()) :: t()
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
  @spec update(t(), map()) :: t()
  def update(user_channel, attrs) do
    struct!(user_channel, attrs)
  end
end
