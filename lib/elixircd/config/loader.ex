defmodule ElixIRCd.Config.Loader do
  @moduledoc "Single configuration entry point for boot, REHASH and offline validation."

  alias ElixIRCd.Config.Error
  alias ElixIRCd.Config.Resources
  alias ElixIRCd.Config.Validator
  alias ElixIRCd.Utils.HostnameCloaking

  @doc "Reads and validates a complete file without changing files or application state."
  @spec read!(String.t()) :: keyword()
  def read!(path) do
    config = read_file!(path)

    case Validator.validate(config) do
      :ok -> config
      {:error, errors} -> raise Error, path: path, errors: errors
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
