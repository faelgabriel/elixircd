import Config

config :elixircd,
  server_name: "Server Example",
  server_hostname: "server.example.com",
  tcp_port: 6667,
  ssl_port: 6697,
  ssl_keyfile: "priv/ssl/key.pem",
  ssl_certfile: "priv/ssl/cert.crt"
