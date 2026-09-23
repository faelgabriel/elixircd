defmodule ElixIRCd.Config.Loader do
  @moduledoc "Single configuration entry point for boot, REHASH and offline validation."

  alias ElixIRCd.Config.Error
  alias ElixIRCd.Config.Resources
  alias ElixIRCd.Config.Validator
  alias ElixIRCd.Utils.HostnameCloaking

  @doc "Reads and validates a complete file without changing files or application state."
  @spec read!(String.t()) :: keyword()
  def read!(path) do
    config = path |> read_file!() |> upgrade_legacy_config()

    case Validator.validate(config) do
      :ok -> config
      {:error, errors} -> raise Error, path: path, errors: errors
    end
  end

  # New protocol features are disabled when absent so configurations copied
  # from an older release remain valid and retain their previous behavior.
  @legacy_capability_defaults [
    account_registration: false,
    chathistory: false,
    channel_rename: false,
    event_playback: false,
    message_redaction: false,
    metadata: false,
    multiline: false,
    read_marker: false
  ]
  @s2s_defaults [
    enabled: false,
    network_id: "local",
    semantic_revision: 1,
    server_id: "local",
    server_name: "local.example.test",
    roster: [[sid: "local", name: "local.example.test", parent: nil]],
    services_authority: nil,
    listener: [
      ip: {127, 0, 0, 1},
      port: 7000,
      keyfile: "data/cert/selfsigned_key.pem",
      certfile: "data/cert/selfsigned.pem",
      cacertfile: "data/cert/selfsigned.pem",
      versions: [:"tlsv1.2", :"tlsv1.3"],
      backlog: 128
    ],
    parent_connection: nil,
    children: %{},
    budgets: [
      max_frame_bytes: 1_048_576,
      max_connections_per_acceptor: 256,
      max_inbound_queue_bytes: 2 * 1_048_576,
      per_link_queue_bytes: 16 * 1_048_576,
      snapshot_delta_queue_bytes: 16 * 1_048_576,
      aggregate_output_bytes: 128 * 1_048_576,
      aggregate_pending_frames: 262_144,
      aggregate_pending_bytes: 128 * 1_048_576,
      snapshot_staging_bytes: 128 * 1_048_576,
      max_pending_requests_origin: 128,
      max_pending_requests_node: 1_024,
      sasl_workers: 4,
      max_pending_frames: 65_536,
      max_stream_parts: 4_096,
      max_stream_bytes: 16 * 1_048_576,
      max_repairs: 16,
      max_list_slots: 4_096,
      max_memberships: 20,
      max_policy_objects: 65_536
    ],
    timeouts: [
      tls_hello_ms: 15_000,
      incomplete_frame_ms: 15_000,
      snapshot_ms: 120_000,
      request_ms: 15_000,
      heartbeat_ms: 30_000,
      heartbeat_timeout_ms: 60_000,
      shutdown_ms: 15_000
    ],
    remote_admin: [enabled: false, actions: [], origin_sids: [], operator_roles: []],
    reconnect: [initial_ms: 1_000, max_ms: 60_000, jitter_ms: 500, stable_ms: 30_000]
  ]
  @legacy_section_defaults [
    compatibility: [
      legacy_invite_order: false,
      deprecated_metadata: false,
      rfc1459_names: false,
      rfc1459_whowas_errors: false
    ],
    history: [
      enabled: false,
      max_entries_per_target: 1_000,
      max_request_limit: 100,
      retention_seconds: 604_800
    ],
    redaction: [enabled: false, max_reason_length: 300],
    metadata: [enabled: false, before_connect: false, max_keys: 20, max_subscriptions: 50, max_value_bytes: 400],
    read_markers: [enabled: false],
    multiline: [enabled: false, max_bytes: 4_096, max_lines: 32],
    account_registration: [enabled: false, before_connect: false],
    channel_rename: [enabled: false, max_reason_length: 300]
  ]

  @spec upgrade_legacy_config(keyword()) :: keyword()
  defp upgrade_legacy_config(config) do
    upgraded =
      config
      |> merge_section_defaults(:s2s, @s2s_defaults)
      |> merge_section_defaults(:capabilities, @legacy_capability_defaults)
      |> merge_section_defaults(:sasl, scram_sha_256: [enabled: false, iterations: 15_000])
      |> merge_nested_section_defaults(:sasl, :scram_sha_256, enabled: false, iterations: 15_000)

    Enum.reduce(@legacy_section_defaults, upgraded, &merge_legacy_section/2)
  end

  @spec merge_legacy_section({atom(), keyword()}, keyword()) :: keyword()
  defp merge_legacy_section({section, defaults}, config), do: merge_section_defaults(config, section, defaults)

  @spec merge_section_defaults(keyword(), atom(), keyword()) :: keyword()
  defp merge_section_defaults(config, section, defaults) do
    case Keyword.fetch(config, section) do
      :error ->
        Keyword.put(config, section, defaults)

      {:ok, value} ->
        if Keyword.keyword?(value), do: Keyword.put(config, section, Keyword.merge(defaults, value)), else: config
    end
  end

  @spec merge_nested_section_defaults(keyword(), atom(), atom(), keyword()) :: keyword()
  defp merge_nested_section_defaults(config, section, nested, defaults) do
    case Keyword.fetch(config, section) do
      {:ok, value} when is_list(value) ->
        if Keyword.keyword?(value),
          do: Keyword.put(config, section, merge_section_defaults(value, nested, defaults)),
          else: config

      _ ->
        config
    end
  end

  @doc "Checks the complete configuration and referenced resources without writing files or activating values."
  @spec check!(String.t()) :: :ok
  def check!(path) do
    path |> read!() |> Resources.prepare!()
    :ok
  end

  @doc "Validates and prepares all resources before applying configuration, without merging old values."
  @spec load!(String.t(), :boot | :reload) :: :ok
  def load!(path, mode) when mode in [:boot, :reload] do
    :global.trans(
      {__MODULE__, self()},
      fn ->
        config = read!(path)
        validate_reload!(config, path, mode)
        prepared = Resources.prepare!(config)
        Resources.write!(prepared.files)
        if mode == :reload, do: :ssl.clear_pem_cache()

        for {key, _value} <- Application.get_all_env(:elixircd),
            not Keyword.has_key?(config, key),
            do: Application.delete_env(:elixircd, key)

        Application.put_all_env(elixircd: config)
        :persistent_term.put(HostnameCloaking, prepared.cloak_key)
        :ok
      end,
      [node()]
    )
  end

  @spec read_file!(String.t()) :: keyword()
  defp read_file!(path) do
    case Config.Reader.read!(path) do
      [{:elixircd, config}] -> config
      _ -> raise Error, path: path, errors: ["expected configuration for :elixircd only"]
    end
  rescue
    error in Error ->
      reraise error, __STACKTRACE__

    error in [SyntaxError, TokenMissingError] ->
      raise Error,
        path: path,
        errors: ["invalid Elixir syntax at line #{error.line}; check delimiters, commas and quotes"]

    error in File.Error ->
      raise Error, path: path, errors: ["cannot #{error.action} #{error.path}: #{:file.format_error(error.reason)}"]

    error ->
      raise Error,
        path: path,
        errors: [
          "configuration evaluation failed (#{inspect(error.__struct__)}); check expressions and referenced files"
        ]
  catch
    kind, _reason -> raise Error, path: path, errors: ["configuration evaluation failed (#{kind})"]
  end

  @spec validate_reload!(keyword(), String.t(), :boot | :reload) :: :ok
  defp validate_reload!(_config, _path, :boot), do: :ok

  defp validate_reload!(config, path, :reload) do
    errors =
      Enum.flat_map([[:listeners], [:settings, :case_mapping], [:server, :hostname]], fn keys ->
        [section | rest] = keys
        old = Enum.reduce(rest, Application.get_env(:elixircd, section), fn key, value -> value[key] end)
        new = Enum.reduce(keys, config, fn key, value -> value[key] end)
        if old == new, do: [], else: ["#{Enum.join(keys, ".")}: change requires server restart"]
      end)

    if errors != [], do: raise(Error, path: path, errors: errors)
    :ok
  end
end
