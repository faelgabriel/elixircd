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
    # IRC port
    {:tcp, [port: 6667]},
    # Alternative IRC port (6668)
    {:tcp, [port: 6668]},
    # SSL-enabled IRC port (6697); paths to SSL key and certificate files
    {:ssl,
     [
       port: 6697,
       keyfile: Path.join([:code.priv_dir(:elixircd), "cert/selfsigned_key.pem"]),
       certfile: Path.join([:code.priv_dir(:elixircd), "cert/selfsigned.pem"])
     ]},
    # Additional SSL-enabled IRC port (6698)
    {:ssl,
     [
       port: 6698,
       keyfile: Path.join([:code.priv_dir(:elixircd), "cert/selfsigned_key.pem"]),
       certfile: Path.join([:code.priv_dir(:elixircd), "cert/selfsigned.pem"])
     ]},
    # WebSocket port (8080)
    {:ws, [port: 8080]},
    # WebSocket SSL port (4443); paths to SSL key and certificate files
    {:wss,
     [
       port: 4443,
       keyfile: Path.join([:code.priv_dir(:elixircd), "cert/selfsigned_key.pem"]),
       certfile: Path.join([:code.priv_dir(:elixircd), "cert/selfsigned.pem"])
     ]}
  ],
  # User Configuration
  user: [
    # User inactivity timeout in milliseconds
    timeout: 180_000
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
