import Config

config :mnesia, :dir, ~c"data/mnesia/#{Mix.env()}"

import_config "#{Mix.env()}.exs"
