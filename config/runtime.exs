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
  # IRC Operators
  operators: [
    {"admin", "$argon2id$v=19$m=65536,t=3,p=4$FDb7o+zPhX+AIfcPDZ7O+g$IBllcYuvYr6dSuAb+qEuB72/YWwTwaTVhmFX2XKp76Q"}
  ]
