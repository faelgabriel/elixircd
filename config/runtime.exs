import Config

config :elixircd,
  server_name: "Server Example",
  server_hostname: "server.example.com",
  tcp_ports: [6667, 6668],
  ssl_ports: [6697, 6698],
  ssl_keyfile: "priv/ssl/key.pem",
  ssl_certfile: "priv/ssl/cert.crt",
  enable_ipv6: true
