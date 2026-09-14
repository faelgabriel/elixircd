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
      unique_operators(config[:operators]) ++ resource_paths(config)
  end

  @spec resource_paths(keyword()) :: [String.t()]
  defp resource_paths(config) do
    pairs =
      Enum.flat_map(config[:listeners], fn
        {:tls, opts} -> [opts[:transport_options]]
        {:https, opts} -> [opts]
        _ -> []
      end)

    roles =
      [{config[:cloaking][:cloak_key_file], :cloak}] ++
        Enum.flat_map(pairs, fn opts ->
          [{opts[:keyfile], :key}, {opts[:certfile], :certificate}]
        end)

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
