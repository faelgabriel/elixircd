defmodule ElixIRCd.Tables.User do
  @moduledoc """
  Module for the User table.
  """

  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.HostnameCloaking

  @enforce_keys [:pid, :transport, :ip_address, :port_connected, :registered, :modes, :last_activity, :created_at]
  use Memento.Table,
    attributes: [
      :pid,
      :transport,
      :ip_address,
      :port_connected,
      :nick_key,
      :nick,
      :hostname,
      :cloaked_hostname,
      :ident,
      :realname,
      :registered,
      :modes,
      :password,
      :away_message,
      :identified_as,
      :capabilities,
      :webirc_gateway,
      :webirc_hostname,
      :webirc_ip,
      :webirc_secure,
      :webirc_used,
      :last_activity,
      :registered_at,
      :created_at
    ],
    index: [:nick_key, :ip_address],
    type: :set

  @type t :: %__MODULE__{
          pid: pid(),
          transport: :tcp | :tls | :ws | :wss,
          ip_address: :inet.ip_address(),
          port_connected: :inet.port_number(),
          nick_key: String.t() | nil,
          nick: String.t() | nil,
          hostname: String.t() | nil,
          cloaked_hostname: String.t() | nil,
          ident: String.t() | nil,
          realname: String.t() | nil,
          registered: boolean(),
          modes: [String.t()],
          password: String.t() | nil,
          away_message: String.t() | nil,
          identified_as: String.t() | nil,
          capabilities: [String.t()],
          webirc_gateway: String.t() | nil,
          webirc_hostname: String.t() | nil,
          webirc_ip: String.t() | nil,
          webirc_secure: boolean() | nil,
          webirc_used: boolean() | nil,
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
          optional(:cloaked_hostname) => String.t() | nil,
          optional(:ident) => String.t() | nil,
          optional(:realname) => String.t() | nil,
          optional(:registered) => boolean(),
          optional(:modes) => [String.t()],
          optional(:password) => String.t() | nil,
          optional(:away_message) => String.t() | nil,
          optional(:identified_as) => String.t() | nil,
          optional(:capabilities) => [String.t()],
          optional(:webirc_gateway) => String.t() | nil,
          optional(:webirc_hostname) => String.t() | nil,
          optional(:webirc_ip) => String.t() | nil,
          optional(:webirc_secure) => boolean() | nil,
          optional(:webirc_used) => boolean() | nil,
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
      |> Map.put_new(:capabilities, [])
      |> Map.put_new(:last_activity, :erlang.system_time(:second))
      |> Map.put_new(:created_at, DateTime.utc_now())
      |> handle_nick_key()
      |> maybe_generate_cloaked_hostname()

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
      |> maybe_generate_cloaked_hostname()

    struct!(user, new_attrs)
  end

  @spec handle_nick_key(t_attrs()) :: t_attrs()
  defp handle_nick_key(%{nick: nick} = attrs) do
    nick_key = if nick != nil, do: CaseMapping.normalize(nick), else: nil
    Map.put(attrs, :nick_key, nick_key)
  end

  defp handle_nick_key(attrs), do: attrs

  @spec maybe_generate_cloaked_hostname(t_attrs()) :: t_attrs()
  defp maybe_generate_cloaked_hostname(attrs) do
    if cloaking_enabled?() and should_generate_cloak?(attrs) do
      generate_cloaked_hostname(attrs)
    else
      attrs
    end
  end

  @spec cloaking_enabled?() :: boolean()
  defp cloaking_enabled? do
    Application.get_env(:elixircd, :cloaking)[:enabled] == true
  end

  @spec should_generate_cloak?(t_attrs()) :: boolean()
  defp should_generate_cloak?(attrs) do
    Map.has_key?(attrs, :hostname) and Map.get(attrs, :ip_address) != nil
  end

  @spec generate_cloaked_hostname(t_attrs()) :: t_attrs()
  defp generate_cloaked_hostname(attrs) do
    ip_address = Map.get(attrs, :ip_address)
    hostname = Map.get(attrs, :hostname)
    cloaked = HostnameCloaking.cloak(ip_address, hostname)
    Map.put(attrs, :cloaked_hostname, cloaked)
  end
end
