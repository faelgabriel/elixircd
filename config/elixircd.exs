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
        refill_rate: 1.0,
        # Maximum number of tokens the bucket can hold.
        # Allows short bursts of messages before throttling begins.
        capacity: 20,
        # Number of tokens consumed per message sent.
        cost: 1,
        # Time window (in milliseconds) during which violations are tracked.
        # A violation occurs when a message is sent without enough tokens.
        window_ms: 60_000,
        # Number of violations allowed within window_ms before disconnecting the user.
        disconnect_threshold: 10
      ],
      # Override the global throttle message rate limits for specific commands
      command_throttle: %{
        "JOIN" => [refill_rate: 0.5, capacity: 20, cost: 5, disconnect_threshold: 5],
        "NICK" => [refill_rate: 0.5, capacity: 5, cost: 5, disconnect_threshold: 5],
        "WHO" => [refill_rate: 0.5, capacity: 5, cost: 3, disconnect_threshold: 5],
        "WHOIS" => [refill_rate: 0.5, capacity: 5, cost: 3, disconnect_threshold: 5]
      },
      # Exceptions for any message rate limiting
      exceptions: [
        # Identified nicknames
        nicknames: [],
        # Host masks (e.g., "*!*@127.0.0.1")
        masks: [],
        # User modes (e.g., "o" for operators)
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
  # Hostname Cloaking Configuration
  cloaking: [
    # Enable or disable hostname cloaking feature
    enabled: true,
    # Secret keys for hostname cloaking (MUST be unique per network and kept secret)
    # Generate secure keys with: :crypto.strong_rand_bytes(32) |> Base.encode64()
    # Use at least 3 keys and keep them at least 30 characters each
    # Multiple keys allow key rotation without breaking existing bans
    cloak_keys: [
      "SecretKey1Random30PlusCharactersGoesHere!!",
      "SecretKey2Random30PlusCharactersGoesHere!!",
      "SecretKey3Random30PlusCharactersGoesHere!!"
    ],
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
  capabilities: [
    # Whether to support extended NAMES with hostmasks (uhnames capability)
    extended_names: true,
    # Whether to support extended user modes in WHO replies (extended-uhlist capability)
    extended_uhlist: true,
    # Whether to support IRCv3 message tags (message-tags capability)
    message_tags: true,
    # Whether to attach account= tags with authenticated nickname (account-tag capability)
    account_tag: true,
    # Whether to send ACCOUNT notifications on identify/logout (account-notify capability)
    account_notify: true,
    # Whether to send AWAY notifications to interested clients (away-notify capability)
    away_notify: true,
    # Whether to allow client-only tags from clients (client-tags capability)
    client_tags: true,
    # Whether to support SERVER-TIME capability adding time= tags
    server_time: true,
    # Whether to support MSGID capability adding msgid= tags
    msgid: true
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
    channel_join_limits: %{"#" => 20, "&" => 5},
    # Maximum entries for each list mode (bans, exceptions, etc)
    # Format: {"mode": max_count, ...}
    max_list_entries: %{"b" => 100},
    # Maximum length of a kick message
    max_kick_message_length: 255,
    # Maximum mode changes per MODE command
    max_modes_per_command: 20,
    # Maximum length for a channel topic
    max_topic_length: 300
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
      # Duration (in seconds) a nickname remains reserved after REGAIN command
      regain_reservation_duration: 60,
      # Default User Settings (Users can change these via /msg NickServ SET)
      settings: [
        # Default for: SET HIDE EMAIL {ON|OFF}
        hide_email: false
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
  # For SMTP, use Bamboo.MuaAdapter which is included with ElixIRCd: https://hexdocs.pm/bamboo_mua/Bamboo.Mua.html
  adapter: Bamboo.LocalAdapter
