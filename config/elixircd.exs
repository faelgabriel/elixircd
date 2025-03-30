import Config

config :elixircd,
  # Server Configuration
  server: [
    # Name of your IRC server
    name: "Server Example",
    # Hostname or domain name of your IRC server
    hostname: "server.example.com",
    # Optional server password; set to `nil` if not required
    password: nil,
    # Message of the Day
    motd: File.read("config/motd.txt")
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
    {:http, [port: 8080, kiwiirc_client: true]},
    # HTTPS port (WebSocket SSL)
    {:https,
     [
       port: 8443,
       kiwiirc_client: true,
       keyfile: Path.expand("data/cert/selfsigned_key.pem"),
       certfile: Path.expand("data/cert/selfsigned.pem")
     ]}
  ],
  # User Configuration
  user: [
    # User inactivity timeout in milliseconds
    timeout: 180_000
  ],
  # IRC Bot Services Configuration
  services: [
    # NickServ Configuration
    nickserv: [
      enabled: true,
      # Minimum password length for registering nicks
      min_password_length: 6,
      # Days until an unused registered nickname expires due to inactivity
      nick_expire_days: 90,
      # Whether email is required for registration
      email_required: false,
      # Time in seconds that a user must be connected before registering (0 = disabled)
      waitreg_time: 120,
      # TODO: Can be set via NickServ SET command
      enforce_nick: false,
      # TODO: Can be set via NickServ SET command
      auto_identify: true,
      # TODO: Can be set via NickServ SET command
      private_info: false,
      # Maximum number of nicks a user can register
      max_nicks_per_user: 3,
      # Whether to allow nick grouping
      allow_nick_grouping: true,
      # TODO: Can be set via NickServ SET command
      kill_protection: true,
      # TODO: Grace period (in seconds) for identifying before nick enforcement
      enforce_delay: 60,
      # TODO: Whether users must be authenticated to change account settings
      require_auth_for_changes: true,
      # TODO: Allow password recovery via email (requires email to be set)
      allow_password_recovery: true,
      # TODO: Authentication session timeout in minutes (0 = session never expires)
      auth_session_timeout: 0,
      # TODO: Duration (in seconds) a nickname remains reserved after RECOVER command
      recover_reservation_duration: 60,
      # TODO: Maximum failed password attempts before temporary lockout
      max_failed_logins: 5,
      # TODO: Lockout period (in minutes) after exceeding failed attempts
      failed_login_block_duration: 15,
      # TODO: Allow nickname authentication via SSL/TLS certificates
      allow_cert_auth: false,
      # TODO: Maximum number of hosts in ACCESS list
      max_access_hosts: 10
    ],
    # ChanServ Configuration
    chanserv: [
      enabled: true,
      # TODO: Maximum channels a user can register
      max_channels_per_user: 10,
      # TODO: Whether channel founders automatically get operator status
      auto_op_founder: true,
      # TODO: Whether channels can be transferred between users
      allow_channel_transfer: true,
      # TODO: Can be set via ChanServ SET command
      mlock_enabled: false,
      # TODO: Can be set via ChanServ SET command
      topic_lock: false,
      # TODO: Can be set via ChanServ SET command
      guard_channel: false,
      # TODO: Can be set via ChanServ SET command
      private_info: false,
      # TODO: Can be set via ChanServ SET command
      restricted_access: false,
      # TODO: Days until an unused channel expires
      channel_expire_days: 90,
      # TODO: Whether to enforce channel registration limits
      enforce_registration_limits: true,
      # TODO: Default ban expiry time in days (0 = no expiry)
      default_ban_expiry: 0,
      # TODO: Maximum number of access entries per channel
      max_access_entries: 50,
      # TODO: Default modes for newly registered channels
      default_channel_modes: "+nt",
      # TODO: Allow auto-kick list (AKICK) functionality
      allow_akick: true,
      # TODO: Maximum entries in AKICK list per channel
      max_akick_entries: 30,
      # TODO: Minimum time (in days) between founder transfers
      founder_transfer_cooldown: 30,
      # TODO: Whether auto-voice can be set for specific users
      allow_auto_voice: true,
      # TODO: Enable fantasy commands (commands in channel prefixed with !)
      fantasy_commands: false,
      # TODO: Maximum number of entrances in the successor list
      max_successors: 3
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
