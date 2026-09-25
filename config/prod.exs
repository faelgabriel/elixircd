import Config

config :logger, level: :info

config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
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
     ]}
