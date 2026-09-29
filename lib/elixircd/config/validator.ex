defmodule ElixIRCd.Config.Validator do
  @moduledoc "Validates complete configuration trees and relationships without side effects."

  alias ElixIRCd.Config.Schema
  alias ElixIRCd.Config.Types

  @doc "Returns all structural errors, followed by semantic checks when the structure is sound."
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(config) do
    errors = check(config, {:keyword, Schema.fields()}, "elixircd")
    errors = if errors == [], do: relationships(config), else: errors

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  @doc "Validates an individual schema node. Error messages omit supplied values."
  @spec check(term(), term(), String.t()) :: [String.t()]
  def check(value, {:optional, type}, path), do: check(value, type, path)
  def check(nil, {:nullable, _type}, _path), do: []
  def check(value, {:nullable, type}, path), do: check(value, type, path)

  def check(value, {:enum, choices}, path),
    do: error_unless(value in choices, path, "expected one of #{inspect(choices)}")

  def check(value, {:integer, min, max}, path),
    do:
      error_unless(is_integer(value) and value >= min and value <= max, path, "expected integer from #{min} to #{max}")

  def check(value, {:keyword, fields}, path) do
    if Keyword.keyword?(value) do
      keys = Keyword.keys(value)
      duplicates = keys -- Enum.uniq(keys)
      duplicate_errors = Enum.map(Enum.uniq(duplicates), &"#{child(path, &1)}: duplicate field")
      duplicate_errors ++ fields_errors(value, fields, path, keys)
    else
      ["#{path}: expected keyword list"]
    end
  end

  def check(value, {:fixed_map, fields}, path) when is_map(value) and not is_struct(value),
    do: fields_errors(value, fields, path, Map.keys(value))

  def check(_value, {:fixed_map, _fields}, path), do: ["#{path}: expected map"]

  def check(value, {:map, key_type, value_type}, path) when is_map(value) and not is_struct(value) do
    Enum.with_index(value, fn {key, val}, index ->
      check(key, key_type, "#{path}[#{index}].key") ++ check(val, value_type, "#{path}[#{index}].value")
    end)
    |> List.flatten()
  end

  def check(_value, {:map, _, _}, path), do: ["#{path}: expected map"]

  # length/1 in a guard rejects improper lists before enumeration; an empty-list comparison cannot do that.
  # credo:disable-for-next-line Credo.Check.Warning.ExpensiveEmptyEnumCheck
  def check(value, {kind, type}, path) when kind in [:list, :nonempty_list] and is_list(value) and length(value) >= 0 do
    empty_errors = error_unless(kind == :list or value != [], path, "expected nonempty list")

    empty_errors ++
      (Enum.with_index(value, fn item, index -> check(item, type, "#{path}[#{index}]") end) |> List.flatten())
  end

  def check(_value, {kind, _type}, path) when kind in [:list, :nonempty_list], do: ["#{path}: expected list"]

  def check(value, {:tuple, types}, path) when is_tuple(value) and tuple_size(value) == length(types) do
    Enum.zip(Tuple.to_list(value), types)
    |> Enum.with_index(fn {item, type}, index -> check(item, type, "#{path}[#{index}]") end)
    |> List.flatten()
  end

  def check(_value, {:tuple, _types}, path), do: ["#{path}: expected tuple"]

  def check({tag, value}, {:tagged, variants}, path) when is_atom(tag) do
    case Keyword.fetch(variants, tag) do
      {:ok, type} -> check(value, type, child(path, tag))
      :error -> ["#{path}: expected transport in #{inspect(Keyword.keys(variants))}"]
    end
  end

  def check(_value, {:tagged, _variants}, path), do: ["#{path}: expected {transport, options}"]

  def check(value, {:variant, key, variants}, path) do
    cond do
      Keyword.keyword?(value) and not Keyword.has_key?(value, key) ->
        ["#{child(path, key)}: required field is missing"]

      Keyword.keyword?(value) and is_atom(value[key]) ->
        case Keyword.fetch(variants, value[key]) do
          {:ok, fields} -> check(value, {:keyword, [{key, {:enum, Keyword.keys(variants)}} | fields]}, path)
          :error -> ["#{child(path, key)}: expected one of #{inspect(Keyword.keys(variants))}"]
        end

      true ->
        ["#{path}: expected keyword list with a supported #{key}"]
    end
  end

  def check(value, type, path) when is_atom(type), do: error_unless(Types.valid?(type, value), path, "expected #{type}")

  @spec fields_errors(keyword() | map(), list(), String.t(), list()) :: [String.t()]
  defp fields_errors(value, fields, path, keys) do
    unknown = Enum.map(Enum.uniq(keys) -- Enum.map(fields, &elem(&1, 0)), &"#{child(path, &1)}: unknown field")

    unknown ++
      Enum.flat_map(fields, fn {key, type} ->
        cond do
          key in keys -> check(value[key], type, child(path, key))
          match?({:optional, _}, type) -> []
          true -> ["#{child(path, key)}: required field is missing"]
        end
      end)
  end

  @spec relationships(keyword()) :: [String.t()]
  defp relationships(config) do
    connection = config[:rate_limiter][:connection][:throttle]
    message = config[:rate_limiter][:message]
    channel = config[:channel]
    listeners = config[:listeners]
    ports = Enum.map(listeners, fn {_kind, opts} -> opts[:port] end)
    prefixes = channel[:channel_prefixes]
    capabilities = config[:capabilities]

    throttle_errors(connection, "elixircd.rate_limiter.connection.throttle") ++
      throttle_errors(message[:throttle], "elixircd.rate_limiter.message.throttle") ++
      Enum.flat_map(message[:command_throttle], fn {command, throttle} ->
        throttle_errors(throttle, "elixircd.rate_limiter.message.command_throttle.#{command}")
      end) ++
      error_unless(
        Enum.sort(Map.keys(channel[:channel_join_limits])) == Enum.sort(prefixes),
        "elixircd.channel.channel_join_limits",
        "must define exactly the configured channel prefixes"
      ) ++
      error_unless(
        length(prefixes) == length(Enum.uniq(prefixes)),
        "elixircd.channel.channel_prefixes",
        "duplicate prefix"
      ) ++
      error_unless(length(ports) == length(Enum.uniq(ports)), "elixircd.listeners", "duplicate port") ++
      server_link_relationships(config, ports) ++
      error_unless(
        not config[:capabilities][:sts] or
          Enum.any?(listeners, fn {kind, opts} -> kind == :tls and opts[:port] == config[:sts][:port] end),
        "elixircd.sts.port",
        "must match a TLS IRC listener when STS is enabled"
      ) ++
      error_unless(
        not config[:cloaking][:cloak_on_connect] or config[:cloaking][:enabled],
        "elixircd.cloaking.cloak_on_connect",
        "requires cloaking.enabled"
      ) ++
      capability_relationships(config, capabilities) ++
      unique_operators(config[:operators]) ++ resource_paths(config)
  end

  defp server_link_relationships(config, irc_ports) do
    links = config[:server_links]
    peers = links[:peers]
    ids = Enum.map(peers, &String.downcase(&1.id))

    error_unless(not links[:enabled] or links[:listen] != nil, "elixircd.server_links.listen", "required when enabled") ++
      error_unless(
        links[:listen] == nil or links[:listen][:port] not in irc_ports,
        "elixircd.server_links.listen.port",
        "must not reuse an IRC listener port"
      ) ++
      error_unless(ids == Enum.uniq(ids), "elixircd.server_links.peers", "duplicate peer id") ++
      error_unless(
        Enum.all?(ids, &(&1 != String.downcase(config[:server][:hostname]))),
        "elixircd.server_links.peers",
        "must not include this server"
      ) ++
      error_unless(
        not links[:enabled] or
          (config[:server][:hostname] == String.downcase(config[:server][:hostname]) and
             Enum.all?(peers, &(&1.id == String.downcase(&1.id)))),
        "elixircd.server_links",
        "server and peer IDs must use lowercase hostnames"
      ) ++
      error_unless(
        links[:enabled] or (links[:listen] == nil and peers == []),
        "elixircd.server_links",
        "listen and peers require enabled: true"
      )
  end

  defp capability_relationships(config, capabilities) do
    sasl = config[:sasl]
    sasl_mechanism? = sasl[:plain][:enabled] or sasl[:scram_sha_256][:enabled] or sasl[:ecdsa][:enabled]

    []
    |> require_if(capabilities[:labeled_response], capabilities[:batch], "labeled_response", "batch")
    |> require_if(capabilities[:chathistory], capabilities[:batch], "chathistory", "batch")
    |> require_if(capabilities[:chathistory], capabilities[:message_tags], "chathistory", "message_tags")
    |> require_if(capabilities[:chathistory], capabilities[:server_time], "chathistory", "server_time")
    |> require_if(capabilities[:chathistory], config[:history][:enabled], "chathistory", "history.enabled")
    |> require_if(capabilities[:event_playback], capabilities[:chathistory], "event_playback", "chathistory")
    |> require_if(capabilities[:message_redaction], capabilities[:chathistory], "message_redaction", "chathistory")
    |> require_if(
      capabilities[:message_redaction],
      config[:redaction][:enabled],
      "message_redaction",
      "redaction.enabled"
    )
    |> require_if(
      capabilities[:message_redaction],
      config[:message_ids][:enabled],
      "message_redaction",
      "message_ids.enabled"
    )
    |> require_if(capabilities[:multiline], capabilities[:batch], "multiline", "batch")
    |> require_if(capabilities[:multiline], capabilities[:message_tags], "multiline", "message_tags")
    |> require_if(capabilities[:multiline], config[:multiline][:enabled], "multiline", "multiline.enabled")
    |> require_if(capabilities[:metadata], capabilities[:batch], "metadata", "batch")
    |> require_if(capabilities[:metadata], config[:metadata][:enabled], "metadata", "metadata.enabled")
    |> require_if(capabilities[:read_marker], config[:read_markers][:enabled], "read_marker", "read_markers.enabled")
    |> require_if(
      capabilities[:account_registration],
      config[:account_registration][:enabled] and config[:services][:nickserv][:enabled],
      "account_registration",
      "account_registration.enabled and services.nickserv.enabled"
    )
    |> require_if(
      capabilities[:channel_rename],
      config[:channel_rename][:enabled],
      "channel_rename",
      "channel_rename.enabled"
    )
    |> require_if(capabilities[:sasl], sasl_mechanism?, "sasl", "at least one enabled SASL mechanism")
    |> Kernel.++(
      error_unless(
        config[:history][:max_request_limit] <= config[:history][:max_entries_per_target],
        "elixircd.history.max_request_limit",
        "must not exceed max_entries_per_target"
      )
    )
  end

  defp require_if(errors, false, _dependency, _path, _requirement), do: errors
  defp require_if(errors, true, true, _path, _requirement), do: errors

  defp require_if(errors, true, false, path, requirement),
    do: errors ++ ["elixircd.capabilities.#{path}: requires #{requirement}"]

  @spec resource_paths(keyword()) :: [String.t()]
  defp resource_paths(config) do
    pairs =
      Enum.flat_map(config[:listeners], fn
        {:tls, opts} -> [opts[:transport_options]]
        {:https, opts} -> [opts]
        _ -> []
      end)

    pairs = if config[:server_links][:listen], do: [config[:server_links][:listen] | pairs], else: pairs

    roles =
      [{config[:cloaking][:cloak_key_file], :cloak}] ++
        Enum.flat_map(pairs, fn opts ->
          [{opts[:keyfile], :key}, {opts[:certfile], :certificate}, {opts[:cacertfile], :ca}]
        end)

    roles = Enum.reject(roles, fn {path, _role} -> is_nil(path) end)

    roles
    |> Enum.group_by(fn {path, _role} -> Path.expand(path) end, &elem(&1, 1))
    |> Enum.flat_map(fn {_path, roles} ->
      error_unless(
        length(Enum.uniq(roles)) == 1,
        "elixircd",
        "cloak, certificate and private key paths must be distinct"
      )
    end)
  end

  @spec throttle_errors(keyword(), String.t()) :: [String.t()]
  defp throttle_errors(throttle, path),
    do: error_unless(throttle[:cost] <= throttle[:capacity], path <> ".cost", "must not exceed capacity")

  @spec unique_operators(list()) :: [String.t()]
  defp unique_operators(operators) do
    names = Enum.map(operators, &elem(&1, 0))
    error_unless(Enum.uniq(names) == names, "elixircd.operators", "duplicate operator name")
  end

  @spec child(String.t(), term()) :: String.t()
  defp child(path, key) when is_atom(key) or is_binary(key), do: path <> "." <> to_string(key)
  defp child(path, _key), do: path <> ".<invalid-key>"

  @spec error_unless(boolean(), String.t(), String.t()) :: [String.t()]
  defp error_unless(true, _path, _message), do: []
  defp error_unless(false, path, message), do: ["#{path}: #{message}"]
end
