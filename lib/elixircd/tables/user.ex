defmodule ElixIRCd.Tables.User do
  @moduledoc """
  Module for the User table.
  """

  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.HostnameCloaking

  @enforce_keys [:uid, :pid, :transport, :ip_address, :port_connected, :registered, :modes, :last_activity, :created_at]
  use Memento.Table,
    attributes: [
      :uid,
      :pid,
      :connection_generation,
      :home_sid,
      :home_boot,
      :owner_rev,
      :membership_rev,
      :effective_nick,
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
      :identified_as_key,
      :sasl_authenticated,
      :sasl_attempts,
      :capabilities,
      :cap_negotiating,
      :cap_version,
      :nick_enforcement_key,
      :nick_enforcement_deadline_at,
      :webirc_gateway,
      :webirc_hostname,
      :webirc_ip,
      :webirc_secure,
      :webirc_used,
      :last_activity,
      :registered_at,
      :created_at
    ],
    index: [:pid, :nick_key, :ip_address, :identified_as_key],
    type: :set

  @type t :: %__MODULE__{
          pid: pid() | nil,
          connection_generation: Identity.id() | nil,
          uid: Identity.id(),
          home_sid: String.t() | nil,
          home_boot: Identity.id() | nil,
          owner_rev: non_neg_integer(),
          membership_rev: non_neg_integer(),
          effective_nick: String.t() | nil,
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
          modes: [ModeRegistry.user_mode()],
          password: String.t() | nil,
          away_message: String.t() | nil,
          identified_as: String.t() | nil,
          identified_as_key: String.t() | nil,
          sasl_authenticated: boolean() | nil,
          sasl_attempts: non_neg_integer() | nil,
          capabilities: [String.t()],
          cap_negotiating: boolean() | nil,
          cap_version: pos_integer(),
          nick_enforcement_key: String.t() | nil,
          nick_enforcement_deadline_at: DateTime.t() | nil,
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
          optional(:pid) => pid() | nil,
          optional(:connection_generation) => Identity.id() | nil,
          optional(:uid) => Identity.id(),
          optional(:home_sid) => String.t() | nil,
          optional(:home_boot) => Identity.id() | nil,
          optional(:owner_rev) => non_neg_integer(),
          optional(:membership_rev) => non_neg_integer(),
          optional(:effective_nick) => String.t() | nil,
          optional(:transport) => :tcp | :tls | :ws | :wss,
          optional(:ip_address) => :inet.ip_address(),
          optional(:port_connected) => :inet.port_number(),
          optional(:nick) => String.t() | nil,
          optional(:hostname) => String.t() | nil,
          optional(:cloaked_hostname) => String.t() | nil,
          optional(:ident) => String.t() | nil,
          optional(:realname) => String.t() | nil,
          optional(:registered) => boolean(),
          optional(:modes) => [ModeRegistry.user_mode()],
          optional(:password) => String.t() | nil,
          optional(:away_message) => String.t() | nil,
          optional(:identified_as) => String.t() | nil,
          optional(:identified_as_key) => String.t() | nil,
          optional(:sasl_authenticated) => boolean() | nil,
          optional(:sasl_attempts) => non_neg_integer() | nil,
          optional(:capabilities) => [String.t()],
          optional(:cap_negotiating) => boolean() | nil,
          optional(:cap_version) => pos_integer(),
          optional(:nick_enforcement_key) => String.t() | nil,
          optional(:nick_enforcement_deadline_at) => DateTime.t() | nil,
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
      |> Map.put_new(:uid, Identity.uid())
      |> Map.put_new(:connection_generation, Identity.nonce())
      |> Map.put_new(:home_sid, local_sid())
      |> Map.put_new(:home_boot, nil)
      |> Map.put_new(:owner_rev, 1)
      |> Map.put_new(:membership_rev, 0)
      |> Map.put_new(:effective_nick, Map.get(attrs, :nick))
      |> Map.put_new(:modes, [])
      |> Map.put_new(:capabilities, [])
      |> Map.put_new(:cap_version, 301)
      |> Map.put_new(:last_activity, :erlang.system_time(:second))
      |> Map.put_new(:created_at, DateTime.utc_now())
      |> handle_nick_key()
      |> handle_identified_as_key()
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
      |> Map.put_new(:owner_rev, (user.owner_rev || 1) + 1)
      |> handle_nick_key()
      |> handle_identified_as_key()
      |> maybe_generate_cloaked_hostname()

    struct!(user, new_attrs)
  end

  @doc "Returns whether two user records identify the same network user."
  @spec same_identity?(t(), t()) :: boolean()
  def same_identity?(%__MODULE__{uid: left}, %__MODULE__{uid: right})
      when is_binary(left) and is_binary(right),
      do: left == right

  def same_identity?(%__MODULE__{pid: left}, %__MODULE__{pid: right})
      when is_pid(left) and is_pid(right),
      do: left == right

  def same_identity?(_left, _right), do: false

  @spec handle_nick_key(t_attrs()) :: t_attrs()
  defp handle_nick_key(%{nick: nick} = attrs) do
    nick_key = if nick != nil, do: CaseMapping.normalize(nick), else: nil
    Map.put(attrs, :nick_key, nick_key)
  end

  defp handle_nick_key(attrs), do: attrs

  @spec handle_identified_as_key(t_attrs()) :: t_attrs()
  defp handle_identified_as_key(%{identified_as: identified_as} = attrs) do
    identified_as_key = if identified_as != nil, do: CaseMapping.normalize(identified_as), else: nil
    Map.put(attrs, :identified_as_key, identified_as_key)
  end

  defp handle_identified_as_key(attrs), do: attrs

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
    Application.fetch_env!(:elixircd, :cloaking)[:enabled] == true
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

  defp local_sid do
    Application.get_env(:elixircd, :s2s, [])
    |> case do
      config when is_list(config) -> Keyword.get(config, :server_id, "local")
      config when is_map(config) -> Map.get(config, :server_id, Map.get(config, "server_id", "local"))
      _ -> "local"
    end
  end
end
