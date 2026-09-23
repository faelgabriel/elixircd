defmodule ElixIRCd.Server.S2S.TLS do
  @moduledoc """
  Small, explicit TLS boundary for ENP/1.

  Certificate verification is performed by OTP's TLS implementation. The
  fingerprint and configured-tree checks remain application checks so a valid
  certificate issued by the trusted CA cannot claim an unrelated roster SID.
  """

  alias ElixIRCd.Server.S2S.Identity

  @doc "Builds the dedicated mutual-TLS listener options for ThousandIsland."
  @spec listener_options(keyword() | map()) :: keyword()
  def listener_options(s2s) do
    listener = section(s2s, :listener)

    [
      port: value(listener, :port, 0),
      transport_module: ThousandIsland.Transports.SSL,
      transport_options: [
        mode: :binary,
        active: false,
        ip: value(listener, :ip, {0, 0, 0, 0}),
        backlog: value(listener, :backlog, 128),
        certfile: value(listener, :certfile, ""),
        keyfile: value(listener, :keyfile, ""),
        cacertfile: value(listener, :cacertfile, ""),
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        versions: value(listener, :versions, [:"tlsv1.2", :"tlsv1.3"])
      ]
    ]
  end

  @doc "Builds outbound mTLS options for the configured parent connection."
  @spec client_options(keyword() | map(), keyword() | map()) :: keyword()
  def client_options(s2s, parent) do
    listener = section(s2s, :listener)
    sni = value(parent, :sni, value(parent, :address, ""))

    [
      mode: :binary,
      active: false,
      verify: :verify_peer,
      cacertfile: value(listener, :cacertfile, ""),
      certfile: value(listener, :certfile, ""),
      keyfile: value(listener, :keyfile, ""),
      versions: value(listener, :versions, [:"tlsv1.2", :"tlsv1.3"]),
      server_name_indication: to_charlist(sni),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      reuse_sessions: false
    ]
    |> maybe_bind(value(parent, :bind_ip, nil))
  end

  @doc "Returns the remote socket address and SHA-256 DER certificate pin."
  @spec peer_info(module(), term()) :: {:ok, map()} | {:error, term()}
  def peer_info(transport_module, socket) do
    with {:ok, {address, port}} <- transport_module.peername(socket),
         {:ok, der} <- transport_module.peercert(socket),
         true <- is_binary(der) do
      {:ok, %{address: address, port: port, certfp: fingerprint(der)}}
    else
      false -> {:error, :missing_peer_certificate}
      {:error, _} = error -> error
      _ -> {:error, :invalid_peer_socket}
    end
  end

  @doc "Returns a lowercase SHA-256 DER certificate fingerprint."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der) when is_binary(der), do: Identity.sha256_hex(der)

  @doc "Checks a configured lowercase hexadecimal pin list."
  @spec pin_allowed?(String.t(), term()) :: boolean()
  def pin_allowed?(certfp, pins) when is_binary(certfp) and is_list(pins) do
    Enum.any?(pins, fn pin ->
      is_binary(pin) and Identity.secure_equal?(String.downcase(pin), String.downcase(certfp))
    end)
  end

  def pin_allowed?(_certfp, _pins), do: false

  @doc "Checks a configured peer hostname against the already observed endpoint."
  @spec address_matches?(term(), term()) :: boolean()
  def address_matches?(expected, actual) when is_binary(expected) and is_binary(actual),
    do: String.downcase(expected) == String.downcase(actual)

  def address_matches?(_expected, _actual), do: true

  @doc "Checks an observed peer address against the optional child IP/CIDR allowlist."
  @spec address_allowed?(term(), term()) :: boolean()
  def address_allowed?(_address, ips) when ips in [nil, []], do: true

  def address_allowed?(address, ips) when is_tuple(address) and is_list(ips) do
    Enum.any?(ips, fn allowed ->
      case CIDR.parse(allowed) do
        %CIDR{} = cidr -> CIDR.match(cidr, address) == {:ok, true}
        {:error, _} -> false
        _ -> false
      end
    end)
  rescue
    _ -> false
  end

  def address_allowed?(_address, _ips), do: false

  defp maybe_bind(options, nil), do: options
  defp maybe_bind(options, ip), do: Keyword.put(options, :ip, ip)

  defp section(config, key) when is_map(config), do: Map.get(config, key, Map.get(config, Atom.to_string(key), %{}))
  defp section(config, key) when is_list(config), do: Keyword.get(config, key, [])
  defp section(_config, _key), do: []

  defp value(section, key, default) when is_map(section),
    do: Map.get(section, key, Map.get(section, Atom.to_string(key), default))

  defp value(section, key, default) when is_list(section), do: Keyword.get(section, key, default)
  defp value(_section, _key, default), do: default
end
