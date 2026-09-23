import Config

config :elixircd,
  # Server Configuration
  server: [
    # Name of the IRC network
    name: "Server Example",
    # Hostname or domain name of the IRC network
    hostname: "irc.test",
    # Optional server password; set to `nil` if not required
    password: nil,
    # Message of the Day: nil to disable, text, or File.read!("config/motd.txt").
    # A configured file must exist and be readable.
    motd: nil
  ],
  # Native ENP/1 server-to-server configuration. It is deliberately disabled
  # until certificates, the shared roster and the parent/child pins are
  # provisioned for this deployment.
  s2s: [
    enabled: false,
    network_id: "local",
    semantic_revision: 1,
    server_id: "local",
    server_name: "local.example.test",
    roster: [
      [sid: "local", name: "local.example.test", parent: nil]
    ],
    services_authority: nil,
    listener: [
      ip: {127, 0, 0, 1},
      port: 7000,
      keyfile: "data/cert/selfsigned_key.pem",
      certfile: "data/cert/selfsigned.pem",
      cacertfile: "data/cert/selfsigned.pem",
      versions: [:"tlsv1.2", :"tlsv1.3"],
      backlog: 128
    ],
    parent_connection: nil,
    children: %{},
    budgets: [
      max_frame_bytes: 1_048_576,
      max_connections_per_acceptor: 256,
      max_inbound_queue_bytes: 2 * 1_048_576,
      per_link_queue_bytes: 16 * 1_048_576,
      snapshot_delta_queue_bytes: 16 * 1_048_576,
      aggregate_output_bytes: 128 * 1_048_576,
      aggregate_pending_frames: 262_144,
      aggregate_pending_bytes: 128 * 1_048_576,
      snapshot_staging_bytes: 128 * 1_048_576,
      max_pending_requests_origin: 128,
      max_pending_requests_node: 1_024,
      sasl_workers: 4,
      max_pending_frames: 65_536,
      max_stream_parts: 4_096,
      max_stream_bytes: 16 * 1_048_576,
      max_repairs: 16,
      max_list_slots: 4_096,
      max_memberships: 20,
      max_policy_objects: 65_536
    ],
    timeouts: [
      tls_hello_ms: 15_000,
      incomplete_frame_ms: 15_000,
      snapshot_ms: 120_000,
      request_ms: 15_000,
      heartbeat_ms: 30_000,
      heartbeat_timeout_ms: 60_000,
      shutdown_ms: 15_000
    ],
    remote_admin: [enabled: false, actions: [], origin_sids: [], operator_roles: []],
    reconnect: [initial_ms: 1_000, max_ms: 60_000, jitter_ms: 500, stable_ms: 30_000]
  ],
  # Rate Limiting Configuration
  rate_limiter: [
    # Connection Rate Limiting Configuration
    connection: [
      # Maximum number of simultaneous open connections per IP
      max_connections_per_ip: 100,
      # Controls how frequently new connections are allowed from the same IP.
      throttle: [
        # Tokens added to the bucket per second.
        # Controls how frequently a connection can be made over time.
        refill_rate: 0.5,
        # Maximum number of tokens the bucket can hold.
        # Allows short bursts of new connections before throttling begins.
        capacity: 20,
        # Number of tokens consumed per connection attempt.
        cost: 3,
        # Time window (in milliseconds) during which violations are tracked.
        # A violation occurs when a connection is attempted without enough tokens.
        window_ms: 60_000,
        # Number of violations allowed within the window before blocking the IP.
        block_threshold: 10,
        # Duration (in milliseconds) to block the IP after exceeding the threshold.
        block_ms: 60_000
      ],
      # Exceptions for any connection rate limiting
      exceptions: [
        # IP addresses
        ips: ["127.0.0.1", "::1"],
        # CIDR ranges (e.g., "192.168.1.0/24")
        cidrs: []
      ]
    ],
    # Controls how frequently messages can be sent by each user.
    message: [
      # Protect against general message floods or rapid message sending per user
      throttle: [
        # Tokens added to the user's bucket per second.
        # Controls how frequently a message can be sent over time.
        refill_rate: 2.0,
        # Maximum number of tokens the bucket can hold.
        # Allows short bursts of messages before throttling begins.
        capacity: 40,
        # Number of tokens consumed per message sent.
        cost: 1,
        # Time window (in milliseconds) during which violations are tracked.
        # A violation occurs when a message is sent without enough tokens.
        window_ms: 60_000,
        # Number of violations allowed within window_ms before disconnecting the user.
        disconnect_threshold: 10
      ],
      # Override the global throttle message rate limits for specific commands
      # Each command entry must contain every throttle field (no partial overrides).
      # Example: %{"JOIN" => [refill_rate: 0.5, capacity: 20, cost: 5, window_ms: 60_000, disconnect_threshold: 5]}
      command_throttle: %{},
      # Exceptions for any message rate limiting
      exceptions: [
        # Identified nicknames
        nicknames: [],
        # Host masks (e.g., "*!*@127.0.0.1")
        masks: [],
        # User modes (e.g., :o for operators)
        umodes: []
      ]
    ]
  ],
  # Settings Configuration
  settings: [
    # Case mapping rules (:rfc1459, :strict_rfc1459, :ascii)
    # Important: Changing case mapping after the server has started and
    # users/channels exist may lead to unexpected behavior.
    case_mapping: :rfc1459,
    # Whether to enforce UTF-8 only traffic support
    utf8_only: true
  ],
  # Explicit opt-ins for withdrawn or conflicting client-protocol behavior.
  # These switches never enable server-to-server linking.
  compatibility: [
    # Accept the historical `INVITE <channel> <nick>` parameter order,
    # including delivery for a channel that does not exist.
    legacy_invite_order: false,
    # Serve the withdrawn metadata-3.2 numeric protocol to clients that did
    # not negotiate draft/metadata-2 or draft/metadata-3.
    deprecated_metadata: false,
    # Omit the channel symbol from RPL_NAMREPLY as required by RFC 1459.
    # This conflicts with RFC 2812 and Modern IRC, so it is disabled by default.
    rfc1459_names: false,
    # Use ERR_NONICKNAMEGIVEN plus RPL_ENDOFWHOWAS for parameterless WHOWAS.
    rfc1459_whowas_errors: false
  ],
  # Hostname Cloaking Configuration
  cloaking: [
    # Enable or disable hostname cloaking feature
    enabled: true,
    # Secret key file, loaded at startup and REHASH; generated automatically if missing with owner-only permissions.
    # Keep it private and preserve it in backups and Docker volumes. File errors abort the configuration reload.
    # Replacing the key changes cloaks; restart and review cloak-based bans after rotation.
    cloak_key_file: "data/cloak.key",
    # Prefix for cloaked hostnames (e.g., "elixir-ABC123.provider.com")
    cloak_prefix: "elixir",
    # Automatically enable cloaking (+x mode) when users connect
    cloak_on_connect: false,
    # Allow users to disable cloaking (remove +x mode)
    cloak_allow_disable: true,
    # Number of domain segments to keep visible in cloaked hostnames
    # E.g., 2 means "user.isp.com" becomes "elixir-HASH.isp.com"
    cloak_domain_parts: 2
  ],
  # IRCv3 Capabilities Configuration
  capabilities: [
    # Whether to support extended NAMES with hostmasks (userhost-in-names capability)
    extended_names: true,
    # Whether to support IRCv3 message tags (message-tags capability)
    message_tags: true,
    # Whether to attach the sender's services account to user messages and invites (account-tag)
    account_tag: true,
    # Whether to send ACCOUNT notifications on identify/logout (account-notify capability)
    account_notify: true,
    # Direct IRCv3 account registration; custom account names are intentionally not advertised.
    account_registration: true,
    # Whether to send AWAY notifications to interested clients (away-notify capability)
    away_notify: true,
    # Whether to support IRCv3 BATCH for grouping related server messages
    batch: true,
    # Whether to notify clients when server capabilities change dynamically (cap-notify capability)
    cap_notify: true,
    # Whether to send CHGHOST notifications when ident/hostname changes (chghost capability)
    chghost: true,
    # Persistent IRCv3 message history and optional event playback.
    chathistory: true,
    channel_rename: true,
    event_playback: true,
    # Whether to echo accepted PRIVMSG/NOTICE/TAGMSG commands back to senders (echo-message capability)
    echo_message: true,
    # Whether to support extended JOIN with account information (extended-join capability)
    extended_join: true,
    # Whether MONITOR subscriptions extend supported presence notifications
    extended_monitor: true,
    # Whether to notify channel members when users are invited (invite-notify capability)
    invite_notify: true,
    # Whether clients can redact persisted messages with server-enforced authorization.
    message_redaction: true,
    # Current metadata-2 plus the metadata-3 draft alias used by older clients.
    metadata: true,
    # Client-originated multiline message batches with bounded buffering.
    multiline: true,
    # Whether to support multiple status prefixes in channel responses (multi-prefix capability)
    multi_prefix: true,
    # Persistent, monotonic per-account read markers.
    read_marker: true,
    # Whether to enable SASL authentication before registration (sasl capability)
    sasl: true,
    # Whether to allow clients to change their real name during the session (setname capability)
    setname: true,
    # Whether to advertise optional structured FAIL/WARN/NOTE replies
    standard_replies: true,
    # Whether to support the server-time capability adding time= tags
    server_time: true,
    # Whether to support LABELED-RESPONSE for correlating server replies with client labels
    labeled_response: true,
    # Whether to support Strict Transport Security (sts capability)
    sts: true
  ],
  # WHOX Extension Configuration
  whox: [
    # Enable extended WHO replies
    enabled: true
  ],
  # Message IDs Configuration
  message_ids: [
    # Enable unique message IDs for clients using message-tags
    enabled: true
  ],
  # Persistent chat history. Retention and per-target limits are enforced on writes.
  history: [
    enabled: true,
    max_entries_per_target: 1_000,
    max_request_limit: 100,
    retention_seconds: 604_800
  ],
  redaction: [
    enabled: true,
    max_reason_length: 300
  ],
  metadata: [
    enabled: true,
    before_connect: true,
    max_keys: 20,
    max_subscriptions: 50,
    max_value_bytes: 400
  ],
  read_markers: [
    enabled: true
  ],
  multiline: [
    enabled: true,
    max_bytes: 4_096,
    max_lines: 32
  ],
  account_registration: [
    enabled: true,
    before_connect: false
  ],
  channel_rename: [
    enabled: true,
    max_reason_length: 300
  ],
  # MONITOR Command Configuration
  monitor: [
    # Enable nickname monitoring
    enabled: true,
    # Maximum number of targets a user can monitor (0 = unlimited)
    max_targets: 100
  ],
  # Strict Transport Security (STS) Configuration
  sts: [
    # TLS port that clients should upgrade to (announced on plaintext connections)
    port: 6697,
    # Duration in seconds for clients to cache the STS policy (announced on TLS connections)
    # Planned withdrawal: keep STS and TLS enabled with duration: 0 so returning clients
    # also clear cached policies. Disabling STS only notifies connected CAP 302 clients;
    # disconnected clients retain their policy until expiration or a secure duration=0 announcement.
    # Common values: 86400 (1 day), 2592000 (30 days), 31536000 (1 year)
    duration: 2_592_000,
    # Whether to allow preloading (clients can cache policy before first connection)
    preload: false
  ],
  # SASL Authentication Configuration
  sasl: [
    # PLAIN mechanism configuration (username/password authentication)
    plain: [
      enabled: true,
      # Require TLS for PLAIN authentication (recommended for security)
      require_tls: true
    ],
    # SCRAM-SHA-256 authenticates without sending the password to the server.
    # Existing accounts receive a verifier after their next valid password login.
    scram_sha_256: [
      enabled: true,
      # RFC 7677 requires at least 4096 iterations. Raising this value affects
      # only newly generated or lazily migrated verifiers.
      iterations: 15_000
    ],
    # ECDSA-NIST256P-CHALLENGE configuration (public-key authentication)
    ecdsa: [
      # Disabled by default until clients have a registered public key.
      enabled: false
    ],
    # General SASL settings
    # Timeout for incomplete SASL sessions (in milliseconds)
    session_timeout_ms: 60_000,
    # Maximum failed authentication attempts per connection
    max_attempts_per_connection: 3
  ],
  # Network Listeners Configuration
  listeners: [
    # IRC port (Plaintext)
    {:tcp, [port: 6667]},
    # TLS-enabled IRC port (SSL)
    {:tls,
     [
       port: 6697,
       transport_options: [
         keyfile: Path.expand("data/cert/selfsigned_key.pem"),
         certfile: Path.expand("data/cert/selfsigned.pem")
       ]
     ]},
    # HTTP port (WebSocket)
    {:http, [port: 8080, startup_log: false, websocket_options: [compress: false]]},
    # HTTPS port (WebSocket SSL)
    {:https,
     [
       port: 8443,
       startup_log: false,
       websocket_options: [compress: false],
       keyfile: Path.expand("data/cert/selfsigned_key.pem"),
       certfile: Path.expand("data/cert/selfsigned.pem")
     ]}
  ],
  # User Configuration
  user: [
    # Inactivity timeout (in milliseconds) before disconnecting an idle user
    inactivity_timeout_ms: 180_000,
    # Maximum length allowed for nicknames
    max_nick_length: 30,
    # Maximum length allowed for ident usernames
    max_ident_length: 10,
    # Maximum length allowed for real names (GECOS)
    max_realname_length: 50,
    # Maximum length allowed for AWAY messages
    max_away_message_length: 200
  ],
  # Channel Configuration
  channel: [
    # Supported channel name prefixes (e.g., public, local channels)
    channel_prefixes: ["#", "&"],
    # Maximum length of a channel name (excluding the prefix character)
    max_channel_name_length: 64,
    # Channel limits (maximum number of channels per user per prefix)
    # Format: %{"prefix" => max_count, ...}
    channel_join_limits: %{"#" => 20, "&" => 5},
    # Maximum entries for each list mode (bans, exceptions, etc)
    # Format: %{mode: max_count, ...}
    max_list_entries: %{b: 100, e: 100, I: 100},
    # Maximum length of a kick message
    max_kick_message_length: 255,
    # Maximum mode changes per MODE command
    max_modes_per_command: 20,
    # Maximum length for a channel topic
    max_topic_length: 300
  ],
  # IRC Bot Services Configuration
  services: [
    email: [from_address: "noreply@irc.test"],
    # NickServ Configuration
    nickserv: [
      # Enable/Disable NickServ service
      enabled: true,
      # Minimum password length for registering nicks
      min_password_length: 6,
      # Days until an unused registered nickname expires due to inactivity
      nick_expire_days: 90,
      # Whether email is required for registration
      email_required: false,
      # Time in seconds that a user must be connected before registering (0 = disabled)
      wait_register_time: 120,
      # Days until an unverified nickname registration expires (0 = never expires)
      unverified_expire_days: 1,
      # Duration (in seconds) a nickname remains reserved after REGAIN command
      regain_reservation_duration: 60,
      # Duration (in seconds) a nickname remains reserved after RECOVER command
      recover_reservation_duration: 60,
      # Maximum number of ACCESS entries per registered nickname
      max_access_entries: 10,
      # Maximum stored inbox memos per NickServ account
      max_memos_per_account: 100,
      # Maximum UTF-8 bytes stored across one account's inbox memos
      max_memo_bytes_per_account: 40_000,
      # Maximum custom properties per NickServ account
      max_properties: 50,
      # Maximum UTF-8 bytes across one account's custom properties
      max_property_bytes: 10_000,
      # Maximum rows returned by NickServ LIST
      max_list_results: 100,
      # Maximum NickServ LIST glob pattern length
      max_list_pattern_length: 128,
      # Maximum user-configurable nickname enforcement grace period (7 days)
      max_enforce_time: 604_800,
      # Maximum grace period used by SET KILL QUICK
      quick_enforce_time: 20,
      # Lifetime of a pending email-change verification code
      email_verification_ttl_seconds: 86_400,
      # Default User Settings (Users can change these via /msg NickServ SET)
      settings: [
        # Default for: SET EMAILMEMOS {ON|OFF|ONLY}
        email_memos: :off,
        # Default for: SET ENFORCE {ON|OFF}
        enforce: false,
        # Default for: SET ENFORCETIME <seconds>
        enforce_time: 60,
        # Default for: SET HIDE EMAIL {ON|OFF}
        hide_email: false,
        # Default for: SET HIDE STATUS {ON|OFF}
        hide_status: false,
        # Default for: SET HIDE USERMASK {ON|OFF}
        hide_usermask: false,
        # Default for: SET HIDE QUIT {ON|OFF}
        hide_quit: false,
        # Default for: SET KILL {ON|QUICK|IMMED|OFF}
        kill: :off,
        # Default for: SET LANGUAGE <language>
        language: "en",
        # Default for: SET MSG {ON|OFF}
        msg: false,
        # Default for: SET NEVERGROUP {ON|OFF}
        never_group: false,
        # Default for: SET NEVEROP {ON|OFF}
        never_op: false,
        # Default for: SET NOGREET {ON|OFF}
        no_greet: false,
        # Default for: SET PRIVATE {ON|OFF}
        private: false,
        # Default for: SET PROPERTY <name> [value]
        property: %{},
        # Default for: SET PUBKEY [key]
        pubkey: nil,
        # Default for: SET QUIETCHG {ON|OFF}
        quiet_chg: false,
        # Default for: SET SECURE {ON|OFF}
        secure: false,
        # Default for: SET URL <url>
        url: nil,
        # Default for: SET DISPLAY <nick>
        display: nil
      ]
    ],
    # ChanServ Configuration
    chanserv: [
      # Enable/Disable ChanServ service
      enabled: true,
      # Minimum password length for channel registration
      min_password_length: 8,
      # Maximum number of channels a single user (NickServ account) can register
      max_registered_channels_per_user: 10,
      # List of channel names or patterns that cannot be registered
      forbidden_channel_names: [
        "#services",
        ~r/^#opers$/
      ],
      # Days until an unused registered channel expires due to inactivity
      channel_expire_days: 90,
      # Default Channel Settings (Applied when a channel is first registered)
      settings: [
        # Default for: SET ENTRYMSG <message>
        entrymsg: nil,
        # Initial mode-lock text displayed by ChanServ INFO, or nil for none
        mlock: nil,
        # Default for: SET KEEPTOPIC {ON|OFF}
        keeptopic: true,
        # Default for: SET OPNOTICE {ON|OFF}
        opnotice: true,
        # Default for: SET PEACE {ON|OFF}
        peace: false,
        # Default for: SET PRIVATE {ON|OFF}
        private: false,
        # Default for: SET RESTRICTED {ON|OFF}
        restricted: false,
        # Default for: SET SECURE {ON|OFF}
        secure: false,
        # Default for: SET FANTASY {ON|OFF}
        fantasy: true,
        # Default for: SET GUARD {ON|OFF}
        guard: true,
        # Default for: SET TOPICLOCK {ON|OFF}
        topiclock: false
      ]
    ]
  ],
  # Ident Service Configuration
  ident_service: [
    # Enable or disable ident service
    enabled: true,
    # Timeout for ident service responses in milliseconds (max: 5_000)
    timeout: 2_000
  ],
  # WebIRC Gateway Configuration
  webirc: [
    # Enable or disable WEBIRC support
    enabled: false,
    # List of authorized WebIRC gateways
    # Each gateway must have: IP address/CIDR, password, and identifier
    gateways: [
      # Example gateway configuration:
      # %{
      #   ips: ["192.168.1.100", "10.0.0.0/8"],  # Allowed IP addresses/CIDRs
      #   password: "secure_gateway_password",    # Authentication password
      #   name: "KiwiIRC Gateway"                 # Gateway identifier
      # }
    ],
    # Verify the gateway-provided hostname against its supplied IP; reject WEBIRC on DNS failure or mismatch.
    # When false, trust the gateway hostname. This does not control hostname lookup during the connection handshake.
    verify_hostname: false,
    # Whether to allow IPv6 addresses
    allow_ipv6: true
  ],
  # Administrative Contact Information
  admin_info: [
    # Name of your IRC server for contact purposes
    server: "Server Example",
    # Location of your server
    location: "Server Location Here",
    # Name of the organization running the server
    organization: "Organization Name Here",
    # Contact email address for server administrators
    email: "admin@example.com"
  ],
  # IRC Operators Credentials
  operators: [
    # Define IRC operators with nickname and Argon2id hashed password
    # Example operator with nick "admin" and hashed "admin" password:
    # {"admin", "$argon2id$v=19$m=4096,t=2,p=4$0Ikum7IgbC2CkId/UJQE7A$n1YVbtPj1nP4EfdL771tPCS1PmK+Q364g14ScJzBaSg"}
  ]

# Mailer Configuration
config :elixircd, ElixIRCd.Utils.Mailer,
  # See shipped adapters at https://github.com/beam-community/bamboo#available-adapters
  # SMTP: Bamboo.Mua (https://hexdocs.pm/bamboo_mua/Bamboo.Mua.html)
  adapter: Bamboo.LocalAdapter
