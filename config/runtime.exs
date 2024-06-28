import Config

config :elixircd,
  # Server Configuration
  server: [
    name: "Server Example",
    hostname: "server.example.com",
    listeners: [
      {:ranch_tcp, [port: 6667]},
      {:ranch_tcp, [port: 6668]},
      {:ranch_ssl, [port: 6697, keyfile: "priv/ssl/key.pem", certfile: "priv/ssl/cert.crt"]},
      {:ranch_ssl, [port: 6698, keyfile: "priv/ssl/key.pem", certfile: "priv/ssl/cert.crt"]}
    ],
    password: nil
    # Message of the Day
    # motd: File.read!("priv/motd.txt"),
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
  # Future: add mask support
  # Future: move to a dedicated config file
  operators: [
    {"admin", "$argon2id$v=19$m=65536,t=3,p=4$FDb7o+zPhX+AIfcPDZ7O+g$IBllcYuvYr6dSuAb+qEuB72/YWwTwaTVhmFX2XKp76Q"}
  ]
