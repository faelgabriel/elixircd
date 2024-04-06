defmodule ElixIRCd.Tables.User do
  @moduledoc """
  Module for the User table.
  """

  @enforce_keys [:port, :socket, :transport, :pid, :registered, :modes, :last_activity, :created_at]
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
      :userid,
      :registered,
      :modes,
      :password,
      :away_message,
      :last_activity,
      :registered_at,
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
          userid: String.t() | nil,
          registered: boolean(),
          modes: [String.t()],
          password: String.t() | nil,
          away_message: String.t() | nil,
          last_activity: integer(),
          registered_at: DateTime.t() | nil,
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:port) => port(),
          optional(:socket) => :inet.socket(),
          optional(:transport) => :ranch_tcp | :ranch_ssl,
          optional(:pid) => pid(),
          optional(:nick) => String.t() | nil,
          optional(:hostname) => String.t() | nil,
          optional(:username) => String.t() | nil,
          optional(:realname) => String.t() | nil,
          optional(:userid) => String.t() | nil,
          optional(:registered) => boolean(),
          optional(:modes) => [String.t()],
          optional(:password) => String.t() | nil,
          optional(:away_message) => String.t() | nil,
          optional(:last_activity) => integer(),
          optional(:registered_at) => DateTime.t() | nil,
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new user.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:registered, false)
      |> Map.put_new(:modes, [])
      |> Map.put_new(:last_activity, :erlang.system_time(:second))
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a user.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(user, attrs) do
    struct!(user, attrs)
  end
end
