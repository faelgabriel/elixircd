defmodule ElixIRCd.Tables.User do
  @moduledoc """
  Module for the User table.
  """

  @enforce_keys [:port, :socket, :transport, :pid, :modes, :created_at]
  use Memento.Table,
    attributes: [
      :port,
      :socket,
      :transport,
      :pid,
      :nick,
      :hostname,
      :username,
      :realname,
      :identity,
      :modes,
      :created_at
    ],
    index: [:nick],
    type: :set

  @type t :: %__MODULE__{
          port: port(),
          socket: :inet.socket(),
          transport: :ranch_tcp | :ranch_ssl,
          pid: pid(),
          nick: String.t() | nil,
          hostname: String.t() | nil,
          username: String.t() | nil,
          realname: String.t() | nil,
          identity: String.t() | nil,
          modes: [tuple()],
          created_at: DateTime.t()
        }

  @doc """
  Create a new user.
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
  Update a user.
  """
  @spec update(t(), map()) :: t()
  def update(user, attrs) do
    struct!(user, attrs)
  end
end