import Config

config :elixircd,
  # Server Configuration
  server: [
    name: "Server Example",
    hostname: "server.example.com",
    password: nil,
    motd: File.read("priv/motd.txt")
  ],
  # Network Configuration
  listeners: [
    # Standard IRC port
    {:tcp, [port: 6667]},
    # Alternative IRC port
    {:tcp, [port: 6668]},
    # SSL port
    {:ssl, [port: 6697, keyfile: "priv/cert/selfsigned_key.pem", certfile: "priv/cert/selfsigned.pem"]},
    # Additional SSL port
    {:ssl, [port: 6698, keyfile: "priv/cert/selfsigned_key.pem", certfile: "priv/cert/selfsigned.pem"]}
  ],
  # User Configuration
  user: [
    timeout: 180_000
  ],
  # Features Configuration
  ident_service: [
    enabled: true,
    timeout: 5_000
  ],
  # Administrative Contact Information
  admin_info: [
    server: "Server Example",
    location: "Server Location Here",
    organization: "Organization Name Here",
    email: "admin@example.com"
  ],
  # IRC Operators
  operators: [
    {"admin", "$argon2id$v=19$m=65536,t=3,p=4$FDb7o+zPhX+AIfcPDZ7O+g$IBllcYuvYr6dSuAb+qEuB72/YWwTwaTVhmFX2XKp76Q"}
  ]
