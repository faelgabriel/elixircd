defmodule ElixIRCd.Tables.User do
  @moduledoc """
  Module for the User table.
  """

  alias ElixIRCd.Utils.CaseMapping

  @enforce_keys [:pid, :transport, :registered, :modes, :last_activity, :created_at]
  use Memento.Table,
    attributes: [
      :pid,
      :transport,
      :ip_address,
      :port_connected,
      :nick_key,
      :nick,
      :hostname,
      :ident,
      :realname,
      :registered,
      :modes,
      :password,
      :away_message,
      :identified_as,
      :last_activity,
      :registered_at,
      :created_at
    ],
    index: [:nick_key],
    type: :set

  @type t :: %__MODULE__{
          pid: pid(),
          transport: :tcp | :tls | :ws | :wss,
          ip_address: :inet.ip_address(),
          port_connected: :inet.port_number(),
          nick_key: String.t() | nil,
          nick: String.t() | nil,
          hostname: String.t() | nil,
          ident: String.t() | nil,
          realname: String.t() | nil,
          registered: boolean(),
          modes: [String.t()],
          password: String.t() | nil,
          away_message: String.t() | nil,
          identified_as: String.t() | nil,
          last_activity: integer(),
          registered_at: DateTime.t() | nil,
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:pid) => pid(),
          optional(:transport) => :tcp | :tls | :ws | :wss,
          optional(:ip_address) => :inet.ip_address(),
          optional(:port_connected) => :inet.port_number(),
          optional(:nick) => String.t() | nil,
          optional(:hostname) => String.t() | nil,
          optional(:ident) => String.t() | nil,
          optional(:realname) => String.t() | nil,
          optional(:registered) => boolean(),
          optional(:modes) => [String.t()],
          optional(:password) => String.t() | nil,
          optional(:away_message) => String.t() | nil,
          optional(:identified_as) => String.t() | nil,
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
      |> handle_nick_key()

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a user.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(user, attrs) do
    new_attrs =
      attrs
      |> handle_nick_key()

    struct!(user, new_attrs)
  end

  @spec handle_nick_key(t_attrs()) :: t_attrs()
  defp handle_nick_key(%{nick: nick} = attrs) do
    nick_key = if nick != nil, do: CaseMapping.normalize(nick), else: nil
    Map.put(attrs, :nick_key, nick_key)
  end

  defp handle_nick_key(attrs), do: attrs
end
