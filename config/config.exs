import Config

# Uncomment this line to set a server name manually, by default it gets the system hostname
# config :elixircd, :server, name: "server.example.com"

import_config "#{Mix.env()}.exs"
