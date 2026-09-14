defmodule ElixIRCd.Config.Schema do
  @moduledoc """
  Declarative configuration contract. Fields are required unless tagged `:optional`.
  Nullable fields must still be present. This module contains no fallback values.

  Add fields here, reusable types in `Types`, and relationships in `Validator`.
  Listener and mail adapter variants deliberately expose validated options only.
  """

  alias ElixIRCd.Command
  alias ElixIRCd.Commands.Mode.UserModes

  @doc "Returns the complete application configuration schema."
  @spec fields() :: keyword()
  def fields do
    [
      {ElixIRCd.Utils.Mailer, {:variant, :adapter, mailer_variants()}},
      server: {:keyword, [name: :text, hostname: :hostname, password: {:nullable, :text}, motd: :motd]},
      settings: {:keyword, [case_mapping: {:enum, [:rfc1459, :strict_rfc1459, :ascii]}, utf8_only: :boolean]},
      rate_limiter:
        {:keyword,
         [
           connection:
             {:keyword,
              [
                max_connections_per_ip: :positive_integer,
                throttle: {:keyword, connection_throttle()},
                exceptions: {:keyword, [ips: {:list, :ip}, cidrs: {:list, :cidr}]}
              ]},
           message:
             {:keyword,
              [
                throttle: {:keyword, message_throttle()},
                command_throttle: {:map, {:enum, Command.names()}, {:keyword, message_throttle()}},
                exceptions:
                  {:keyword,
                   [
                     nicknames: {:list, :nickname},
                     masks: {:list, :mask},
                     umodes: {:list, {:enum, UserModes.modes()}}
                   ]}
              ]}
         ]},
      cloaking:
        {:keyword,
         [
           enabled: :boolean,
           cloak_key_file: :path,
           cloak_prefix: :cloak_prefix,
           cloak_on_connect: :boolean,
           cloak_allow_disable: :boolean,
           cloak_domain_parts: {:integer, 1, 127}
         ]},
      capabilities:
        {:keyword,
         boolean_fields([
           :extended_names,
           :message_tags,
           :account_tag,
           :account_notify,
           :away_notify,
           :batch,
           :cap_notify,
           :chghost,
           :echo_message,
           :extended_join,
           :invite_notify,
           :multi_prefix,
           :sasl,
           :setname,
           :standard_replies,
           :server_time,
           :labeled_response,
           :sts
         ])},
      whox: {:keyword, [enabled: :boolean]},
      message_ids: {:keyword, [enabled: :boolean]},
      monitor: {:keyword, [enabled: :boolean, max_targets: :non_negative_integer]},
      sts: {:keyword, [port: :port, duration: :non_negative_integer, preload: :boolean]},
      sasl:
        {:keyword,
         [
           plain: {:keyword, [enabled: :boolean, require_tls: :boolean]},
           session_timeout_ms: :positive_integer,
           max_attempts_per_connection: :positive_integer
         ]},
      listeners: {:nonempty_list, {:tagged, listener_variants()}},
      user:
        {:keyword,
         [
           inactivity_timeout_ms: :positive_integer,
           max_nick_length: {:integer, 1, 64},
           max_ident_length: {:integer, 1, 64},
           max_realname_length: {:integer, 1, 300},
           max_away_message_length: {:integer, 1, 400}
         ]},
      channel:
        {:keyword,
         [
           channel_prefixes: {:nonempty_list, {:enum, ["#", "&"]}},
           max_channel_name_length: {:integer, 1, 200},
           channel_join_limits: {:map, {:enum, ["#", "&"]}, :positive_integer},
           max_list_entries:
             {:fixed_map, [{"b", :positive_integer}, {"e", :positive_integer}, {"I", :positive_integer}]},
           max_kick_message_length: {:integer, 1, 400},
           max_modes_per_command: :positive_integer,
           max_topic_length: {:integer, 1, 400}
         ]},
      services:
        {:keyword,
         [
           email: {:keyword, [from_address: :email]},
           nickserv:
             {:keyword,
              [
                enabled: :boolean,
                min_password_length: :positive_integer,
                nick_expire_days: :positive_integer,
                email_required: :boolean,
                wait_register_time: :non_negative_integer,
                unverified_expire_days: :non_negative_integer,
                regain_reservation_duration: :positive_integer,
                recover_reservation_duration: :positive_integer,
                max_access_entries: :positive_integer,
                settings: {:keyword, [hide_email: :boolean]}
              ]},
           chanserv:
             {:keyword,
              [
                enabled: :boolean,
                min_password_length: :positive_integer,
                max_registered_channels_per_user: :positive_integer,
                forbidden_channel_names: {:list, :channel_pattern},
                channel_expire_days: :positive_integer,
                settings:
                  {:keyword,
                   [entrymsg: {:nullable, :text}, mlock: {:nullable, :text}] ++
                     boolean_fields([
                       :keeptopic,
                       :opnotice,
                       :peace,
                       :private,
                       :restricted,
                       :secure,
                       :fantasy,
                       :guard,
                       :topiclock
                     ])}
              ]}
         ]},
      ident_service: {:keyword, [enabled: :boolean, timeout: {:integer, 1, 5_000}]},
      webirc:
        {:keyword,
         [
           enabled: :boolean,
           gateways: {:list, {:fixed_map, [ips: {:nonempty_list, :ip_or_cidr}, password: :token, name: :text]}},
           verify_hostname: :boolean,
           allow_ipv6: :boolean
         ]},
      admin_info: {:keyword, [server: :text, location: :text, organization: :text, email: :email]},
      operators: {:list, {:tuple, [:token, :argon2_hash]}}
    ]
  end

  @doc "Connection throttle fields."
  @spec connection_throttle() :: keyword()
  def connection_throttle do
    [
      refill_rate: :positive_number,
      capacity: :positive_integer,
      cost: :non_negative_integer,
      window_ms: :positive_integer,
      block_threshold: :positive_integer,
      block_ms: :positive_integer
    ]
  end

  @doc "Each command override is complete and does not inherit missing throttle fields."
  @spec message_throttle() :: keyword()
  def message_throttle do
    [
      refill_rate: :positive_number,
      capacity: :positive_integer,
      cost: :non_negative_integer,
      window_ms: :positive_integer,
      disconnect_threshold: :positive_integer
    ]
  end

  @doc "Supported listener transports and their options."
  @spec listener_variants() :: keyword()
  def listener_variants do
    tuning = [
      num_acceptors: {:optional, :positive_integer},
      num_connections: {:optional, :connection_limit},
      num_listen_sockets: {:optional, :positive_integer},
      max_connections_retry_count: {:optional, :non_negative_integer},
      max_connections_retry_wait: {:optional, :timeout},
      silent_terminate_on_error: {:optional, :boolean},
      read_timeout: {:optional, :timeout},
      shutdown_timeout: {:optional, :timeout}
    ]

    socket = [ip: {:optional, :ip_tuple}, backlog: {:optional, :positive_integer}, nodelay: {:optional, :boolean}]

    tls = [
      keyfile: :path,
      certfile: :path,
      cacertfile: {:optional, :path},
      versions: {:optional, {:nonempty_list, {:enum, [:"tlsv1.2", :"tlsv1.3"]}}}
    ]

    http = [
      port: :port,
      startup_log: {:enum, [false, :debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]},
      ip: {:optional, :ip_tuple},
      thousand_island_options: {:optional, {:keyword, tuning}},
      websocket_options: {:keyword, [compress: :boolean]}
    ]

    [
      tcp: {:keyword, [port: :port, transport_options: {:optional, {:keyword, socket}}] ++ tuning},
      tls: {:keyword, [port: :port, transport_options: {:keyword, tls ++ socket}] ++ tuning},
      http: {:keyword, http},
      https: {:keyword, http ++ tls}
    ]
  end

  @doc "Supported mail delivery adapters. SMTP credentials and transport choices are explicit."
  @spec mailer_variants() :: keyword()
  def mailer_variants do
    [
      {Bamboo.LocalAdapter, [open_email_in_browser_url: {:optional, :url}]},
      {Bamboo.TestAdapter, []},
      {Bamboo.SendGridAdapter,
       [api_key: :text, hackney_opts: {:keyword, [recv_timeout: :timeout, connect_timeout: :timeout]}]},
      {Bamboo.MandrillAdapter,
       [api_key: :text, hackney_opts: {:keyword, [recv_timeout: :timeout, connect_timeout: :timeout]}]},
      {Bamboo.MailgunAdapter,
       [
         api_key: :text,
         domain: :hostname,
         base_uri: :url,
         hackney_opts: {:keyword, [recv_timeout: :timeout, connect_timeout: :timeout]}
       ]},
      {Bamboo.Mua,
       [
         relay: :hostname,
         port: :port,
         auth: {:nullable, {:keyword, [username: :text, password: :text]}},
         protocol: {:enum, [:tcp, :ssl]},
         timeout: :timeout,
         mx: :boolean,
         ssl: {:keyword, [verify: {:enum, [:verify_peer, :verify_none]}, cacertfile: {:optional, :path}]},
         tcp: {:keyword, [nodelay: :boolean]}
       ]}
    ]
  end

  @spec boolean_fields([atom()]) :: keyword()
  defp boolean_fields(names), do: Enum.map(names, &{&1, :boolean})
end
