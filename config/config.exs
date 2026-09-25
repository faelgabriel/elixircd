import Config

config :logger, :default_formatter,
  metadata: [
    :event,
    :connection_id,
    :transport,
    :reason,
    :command,
    :result,
    :service,
    :action,
    :actor,
    :job_type,
    :job_id,
    :error_type
  ]

config :mnesia, :dir, ~c"data/mnesia/#{Mix.env()}"

import_config "#{Mix.env()}.exs"
