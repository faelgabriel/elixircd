import Config

config :elixircd,
  # Server Configuration
  server: [
    # Name of your IRC server
    name: "Server Example",
    # Hostname or domain name of your IRC server
    hostname: "irc.test",
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
    # User inactivity timeout in milliseconds
    timeout: 180_000
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

      # # TODO: Maximum number of nicks a user can register/group
      # max_nicks_per_user: 3,

      # # TODO: Whether to allow nick grouping features (GROUP, UNGROUP, SET NEVERGROUP etc.)
      # allow_nick_grouping: true,

      # # TODO: Whether users must be authenticated (identified) to change account settings
      # require_auth_for_changes: true,

      # # TODO: Allow password recovery via email (requires email server config and email_required or user SET EMAIL)
      # allow_password_recovery: true,

      # # TODO: Authentication session timeout in minutes (0 = session never expires)
      # auth_session_timeout: 0,

      # # Duration (in seconds) a nickname remains reserved after REGAIN command
      # regain_reservation_duration: 60,

      # # TODO: Maximum failed password attempts before temporary lockout
      # max_failed_logins: 5,

      # # TODO: Lockout period (in minutes) after exceeding failed attempts
      # failed_login_block_duration: 15,

      # # TODO: Allow nickname authentication via SSL/TLS certificates (using CERT command)
      # allow_cert_auth: false,

      # # TODO: Maximum number of hosts allowed in a user's ACCESS list
      # max_access_hosts: 10,

      # Default User Settings (Users can change these via /msg NickServ SET)
      settings: [
        # # TODO: Default for: SET EMAILMEMOS {ON|OFF|ONLY}
        # email_memos: :off,
        # # TODO: Default for: SET ENFORCE {ON|OFF} (Master switch for KILL etc.)
        # enforce: true,
        # # TODO: Default for: SET ENFORCETIME <seconds> (Delay for KILL ON)
        # enforce_time: 60,
        # Default for: SET HIDE EMAIL {ON|OFF}
        hide_email: false
        # # TODO: Default for: SET HIDE STATUS {ON|OFF}
        # hide_status: false,
        # # TODO: Default for: SET HIDE USERMASK {ON|OFF}
        # hide_usermask: false,
        # # TODO: Default for: SET HIDE QUIT {ON|OFF}
        # hide_quit: false,
        # # TODO: Default for: SET KILL {ON|QUICK|IMMED|OFF}
        # kill: :on,
        # # TODO: Default for: SET LANGUAGE <language_code>
        # language: "en",
        # # TODO: Default for: SET MSG {ON|OFF} (true=PRIVMSG, false=NOTICE)
        # msg: false,
        # # TODO: Default for: SET NEVERGROUP {ON|OFF}
        # never_group: false,
        # # TODO: Default for: SET NEVEROP {ON|OFF}
        # never_op: false,
        # # TODO: Default for: SET NOGREET {ON|OFF}
        # no_greet: false,
        # # TODO: Default for: SET PRIVATE {ON|OFF}
        # private: false,
        # # TODO: Default for: SET QUIETCHG {ON|OFF}
        # quiet_chg: false,
        # # TODO: Default for: SET SECURE {ON|OFF}
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

      # # TODO: Should dropping a channel require a confirmation code/step?
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

      # # TODO: Flag mappings for predefined XOP levels
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

      # # TODO: Define custom roles here if implementing the ROLE command
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
