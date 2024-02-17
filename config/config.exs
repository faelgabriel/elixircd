import Config

config :mnesia, :dir, ~c"priv/mnesia.#{Mix.env()}"

import_config "#{Mix.env()}.exs"
