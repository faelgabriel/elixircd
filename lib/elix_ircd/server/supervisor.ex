defmodule ElixIRCd.Server.Supervisor do
  @moduledoc """
  Supervisor for the SSL server.
  """

  require Logger

  use Supervisor

  @doc """
  Starts the SSL server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    tcp_children = tcp_child_specs()
    ssl_children = ssl_child_specs()

    Supervisor.init(tcp_children ++ ssl_children, strategy: :one_for_one)
  end

  @spec tcp_child_specs() :: [Supervisor.child_spec()]
  defp tcp_child_specs do
    tcp_ports = Application.get_env(:elixircd, :tcp_ports)

    Enum.map(tcp_ports, fn port ->
      :ranch.child_spec({__MODULE__, port}, :ranch_tcp, [{:port, port}], ElixIRCd.Server, [])
    end)
  end

  @spec ssl_child_specs() :: [Supervisor.child_spec()]
  defp ssl_child_specs do
    ssl_keyfile = Application.get_env(:elixircd, :ssl_keyfile)
    ssl_certfile = Application.get_env(:elixircd, :ssl_certfile)

    case check_cert_and_key(ssl_certfile, ssl_keyfile) do
      :ok ->
        ssl_ports = Application.get_env(:elixircd, :ssl_ports)

        Enum.map(ssl_ports, fn port ->
          :ranch.child_spec(
            {__MODULE__, port},
            :ranch_ssl,
            [
              {:port, port},
              {:keyfile, ssl_keyfile},
              {:certfile, ssl_certfile}
            ],
            ElixIRCd.Server,
            []
          )
        end)

      {:error, reason} ->
        Logger.error("SSL certificate error: #{reason}")
        []
    end
  end

  @spec check_cert_and_key(String.t(), String.t()) :: :ok | {:error, String.t()}
  # sobelow_skip ["Traversal.FileModule"]
  defp check_cert_and_key(cert_file, key_file) do
    with {:ok, cert_data} <- File.read(cert_file),
         {:ok, key_data} <- File.read(key_file),
         {:ok, cert_entry} <- decode_cert(cert_data),
         {:ok, key_entry} <- decode_key(key_data),
         :ok <- validate_cert_and_key(cert_entry, key_entry) do
      :ok
    else
      {:error, error} when is_binary(error) ->
        {:error, error}

      {:error, _} ->
        {:error, "Error reading certificate or private key"}
    end
  end

  @spec decode_cert(binary()) :: {:ok, tuple()} | {:error, String.t()}
  defp decode_cert(cert_data) do
    case :public_key.pem_decode(cert_data) do
      [cert_entry] -> {:ok, cert_entry}
      _ -> {:error, "Error decoding certificate"}
    end
  end

  @spec decode_key(binary()) :: {:ok, tuple()} | {:error, String.t()}
  defp decode_key(key_data) do
    case :public_key.pem_decode(key_data) do
      [key_entry] -> {:ok, key_entry}
      _ -> {:error, "Error decoding private key"}
    end
  end

  @spec validate_cert_and_key(tuple(), tuple()) :: :ok | {:error, String.t()}
  defp validate_cert_and_key(cert_entry, key_entry) do
    case {cert_entry, key_entry} do
      {{:Certificate, _, _}, {:RSAPrivateKey, _, _}} -> :ok
      {{:Certificate, _, _}, {:ECPrivateKey, _, _}} -> :ok
      _ -> {:error, "Certificate or private key is invalid"}
    end
  end
end
