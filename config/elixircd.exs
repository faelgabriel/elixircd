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
    # Message of the Day
    motd: File.read("config/motd.txt")
  ],
  # Rate Limiting Configuration
  rate_limiter: [
    # Connection Rate Limiting Configuration
    connection: [
      # IPs that bypass connection rate limiting
      # TODO: move to 'exceptions': "masks" and "ips" lists; support ip ranges, e.g. 192.168.0.0/16
      whitelist: ["127.0.0.1", "::1"],
      # Maximum number of simultaneous open connections per IP
      # TODO: validate the max_per_ip value on new connections
      max_per_ip: 100,
      # Controls how frequently new connections are allowed from the same IP.
      throttle: [
        # Tokens added to the bucket per second.
        # Controls how frequently a connection can be made over time.
        refill_rate: 0.05,
        # Maximum number of tokens the bucket can hold.
        # Allows short bursts of new connections before throttling begins.
        capacity: 3,
        # Number of tokens consumed per connection attempt.
        cost: 1,
        # Time window (in milliseconds) during which violations are tracked.
        # A violation occurs when a connection is attempted without enough tokens.
        window_ms: 60_000,
        # Number of violations allowed within the window before blocking the IP.
        block_threshold: 2,
        # Duration (in milliseconds) to block the IP after exceeding the threshold.
        block_ms: 60_000
      ]
    ],
    # Controls how frequently messages can be sent by each user.
    message: [
      # Protect against general message floods or rapid message sending per user
      throttle: [
        # Tokens added to the user's bucket per second.
        # Controls how frequently a message can be sent over time.
        refill_rate: 1.0,
        # Maximum number of tokens the bucket can hold.
        # Allows short bursts of messages before throttling begins.
        capacity: 10,
        # Number of tokens consumed per message sent.
        cost: 1,
        # Time window (in milliseconds) during which violations are tracked.
        # A violation occurs when a message is sent without enough tokens.
        window_ms: 60_000,
        # Number of violations allowed within window_ms before disconnecting the user.
        disconnect_threshold: 5
      ],
      # Override the global throttle message rate limits for specific commands
      command_throttle: %{
        "JOIN" => [refill_rate: 0.3, capacity: 3, cost: 1, window_ms: 10_000, disconnect_threshold: 2],
        "PING" => [refill_rate: 2.0, capacity: 10, cost: 0],
        "NICK" => [refill_rate: 0.1, capacity: 1, cost: 3],
        "WHO" => [refill_rate: 0.2, capacity: 2, cost: 1],
        "WHOIS" => [refill_rate: 0.2, capacity: 2, cost: 1]
      }
      # TODO: support 'exceptions': "nicks", "accounts", "masks", and "umodes".
    ]
  ],
  # Features Configuration
  features: [
    # Case mapping rules (:rfc1459, :strict_rfc1459, :ascii)
    # Important: Changing case mapping after the server has started and
    # users/channels exist may lead to unexpected behavior.
    case_mapping: :rfc1459,
    # TODO: Support for extended NAMES with hostmasks
    support_extended_names: true,
    # TODO: Support for CALLERID (mode +g)
    support_callerid_mode: true,
    # TODO: Maximum number of monitored nicknames per user
    max_monitored_nicks: 100,
    # TODO: Maximum number of silence list entries per user
    max_silence_entries: 20
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
    {:http, [port: 8080]},
    # HTTPS port (WebSocket SSL)
    {:https,
     [
       port: 8443,
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
    # For example, %{"#" => 20, "&" => 5} means a user can join up to 20 #-channels and 5 &-channels
    channel_join_limits: %{"#" => 20, "&" => 5},
    # TODO: Support for ban exceptions (mode +e)
    support_ban_exceptions: true,
    # TODO: Support for invite exceptions (mode +I)
    support_invite_exceptions: true,
    # TODO: Maximum entries for each list mode (bans, exceptions, etc)
    # Format: {"mode": max_count, ...}
    max_list_entries: %{"b" => 100, "e" => 50, "I" => 50},
    # TODO: Maximum length of a kick message
    max_kick_message_length: 255,
    # TODO: Maximum mode changes per MODE command
    max_modes_per_command: 4,
    # TODO: Maximum length for a channel topic
    max_topic_length: 300,
    # TODO: Channel status prefixes and corresponding modes
    # Format: {"modes": "prefixes"}
    status_prefixes: %{modes: "ov", prefixes: "@+"},
    # TODO: Support for status-specific messages
    status_message_targets: "@+",
    # TODO: Maximum targets for specific commands
    # Format: {"command": max_targets, ...}
    max_command_targets: %{"PRIVMSG" => 4, "NOTICE" => 4, "JOIN" => 4, "PART" => 4}
  ],
  # IRC Bot Services Configuration
  services: [
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
      # TODO: Maximum number of nicks a user can register/group
      # max_nicks_per_user: 3,
      # TODO: Whether to allow nick grouping features (GROUP, UNGROUP, SET NEVERGROUP etc.)
      # allow_nick_grouping: true,
      # TODO: Whether users must be authenticated (identified) to change account settings
      # require_auth_for_changes: true,
      # TODO: Allow password recovery via email (requires email server config and email_required or user SET EMAIL)
      # allow_password_recovery: true,
      # TODO: Authentication session timeout in minutes (0 = session never expires)
      # auth_session_timeout: 0,
      # Duration (in seconds) a nickname remains reserved after REGAIN command
      regain_reservation_duration: 60,
      # TODO: Maximum failed password attempts before temporary lockout
      # max_failed_logins: 5,
      # TODO: Lockout period (in minutes) after exceeding failed attempts
      # failed_login_block_duration: 15,
      # TODO: Allow nickname authentication via SSL/TLS certificates (using CERT command)
      # allow_cert_auth: false,
      # TODO: Maximum number of hosts allowed in a user's ACCESS list
      # max_access_hosts: 10,
      # Default User Settings (Users can change these via /msg NickServ SET)
      settings: [
        # TODO: Default for: SET EMAILMEMOS {ON|OFF|ONLY}
        # email_memos: :off,
        # TODO: Default for: SET ENFORCE {ON|OFF} (Master switch for KILL etc.)
        # enforce: true,
        # TODO: Default for: SET ENFORCETIME <seconds> (Delay for KILL ON)
        # enforce_time: 60,
        # Default for: SET HIDE EMAIL {ON|OFF}
        hide_email: false
        # TODO: Default for: SET HIDE STATUS {ON|OFF}
        # hide_status: false,
        # TODO: Default for: SET HIDE USERMASK {ON|OFF}
        # hide_usermask: false,
        # TODO: Default for: SET HIDE QUIT {ON|OFF}
        # hide_quit: false,
        # TODO: Default for: SET KILL {ON|QUICK|IMMED|OFF}
        # kill: :on,
        # TODO: Default for: SET LANGUAGE <language_code>
        # language: "en",
        # TODO: Default for: SET MSG {ON|OFF} (true=PRIVMSG, false=NOTICE)
        # msg: false,
        # TODO: Default for: SET NEVERGROUP {ON|OFF}
        # never_group: false,
        # TODO: Default for: SET NEVEROP {ON|OFF}
        # never_op: false,
        # TODO: Default for: SET NOGREET {ON|OFF}
        # no_greet: false,
        # TODO: Default for: SET PRIVATE {ON|OFF}
        # private: false,
        # TODO: Default for: SET QUIETCHG {ON|OFF}
        # quiet_chg: false,
        # TODO: Default for: SET SECURE {ON|OFF}
        # secure: false
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
      # TODO: Should dropping a channel require a confirmation code/step?
      # require_drop_confirmation: true,
      # Default Channel Settings (Applied when a channel is first registered)
      settings: [
        # Default for: SET ENTRYMSG <message>
        entrymsg: nil,
        # TODO: Default for: SET MODELOCK <modes>
        # mode_lock: nil,
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
      # TODO: Flag mappings for predefined XOP levels
      # xop_levels: [
      #   # SOP - Superior Operator Preset
      #   sop: "+AFORsekbhituav",
      #   # AOP - Administrator/Advanced Operator Preset
      #   aop: "+AORehkbituv",
      #   # HOP - Half Operator Preset
      #   hop: "+HRehkitv",
      #   # VOP - Voice Preset
      #   vop: "+Vv"
      # ]
      # TODO: Define custom roles here if implementing the ROLE command
      # custom_roles: [
      #   moderator: "+HRehkbituv",
      #   helper: "+Vv"
      # ]
    ]
  ],
  # Ident Service Configuration
  ident_service: [
    # Enable or disable ident service
    enabled: true,
    # Timeout for ident service responses in milliseconds (max: 5_000)
    timeout: 2_000
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
    # Define IRC operators with nickname and Pbkdf2 hashed password
    # Example operator with nick "admin" and hashed "admin" password:
    # {"admin", "$pbkdf2-sha512$160000$cwDGS9z9xoJrV.wkfFbbqA$GLkyuwlc2hDD2O8BZeaeLbOLESMYSn0pvcCiVMa0jr2TB25Lswg74ReGKAdDQl3wJ.OLd0ggzwp9BJAgWsx9uw"}
  ]

# Mailer Configuration
config :elixircd, ElixIRCd.Utils.Mailer,
  # See shipped adapters at https://github.com/beam-community/bamboo#available-adapters
  # For SMTP, use Bamboo.MuaAdapter which is included with ElixIRCd: https://hexdocs.pm/bamboo_mua/Bamboo.Mua.html
  adapter: Bamboo.LocalAdapter
