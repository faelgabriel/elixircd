import Config

config :elixircd,
  # TODO: add one more level of configuration for the server and client like it is in the help doc?
  # Server Configuration
  server_name: "Server Example",
  server_hostname: "server.example.com",
  server_listeners: [
    ranch_tcp: [port: 6667],
    ranch_tcp: [port: 6668],
    ranch_ssl: [port: 6697, keyfile: "priv/ssl/key.pem", certfile: "priv/ssl/cert.crt"],
    ranch_ssl: [port: 6698, keyfile: "priv/ssl/key.pem", certfile: "priv/ssl/cert.crt"]
  ],
  server_password: nil,
  # Client Configuration
  client_timeout: 180_000,
  # Features Configuration
  ## Identification Protocol
  ident_protocol_enabled: true,
  ident_protocol_timeout: 5_000
