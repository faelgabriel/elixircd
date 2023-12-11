import Config

# Uncomment this line to set a server name manually, by default it gets the system hostname
# config :elixircd,
#  :server, name: "server.example.com"

config :mnesia,
  dir: ~c".mnesia/#{Mix.env()}/#{node()}"

import_config "#{Mix.env()}.exs"
