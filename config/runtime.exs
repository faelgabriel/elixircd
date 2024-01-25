import Config

config :elixircd,
  server_name: "Server Example",
  server_hostname: "server.example.com",
  server_listeners: [
    {:ranch_tcp, [port: 6667]},
    {:ranch_tcp, [port: 6668]},
    {:ranch_ssl, [port: 6697, keyfile: "priv/ssl/key.pem", certfile: "priv/ssl/cert.crt"]},
    {:ranch_ssl, [port: 6698, keyfile: "priv/ssl/key.pem", certfile: "priv/ssl/cert.crt"]}
  ],
  client_timeout: 180_000
