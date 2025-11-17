defmodule ElixIRCd.Commands.Webirc do
  @moduledoc """
  This module defines the WEBIRC command.

  WEBIRC allows WebIRC gateways to provide real IP and hostname information
  for clients connecting through proxies/gateways.

  Specification: https://ircv3.net/specs/extensions/webirc.html
  """

  @behaviour ElixIRCd.Command

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Network

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok | {:quit, String.t()}

  def handle(user, %{command: "WEBIRC"} = message) do
    case webirc_enabled?() do
      false -> error_and_close(user, "WEBIRC is not enabled on this server")
      true -> handle_enabled(user, message)
    end
  end

  @spec handle_enabled(User.t(), Message.t()) :: :ok | {:quit, String.t()}
  defp handle_enabled(%{registered: true} = user, _message) do
    error_and_close(user, "WEBIRC must be sent before registration")
  end

  defp handle_enabled(user, _message) when user.webirc_used == true do
    error_and_close(user, "WEBIRC can only be used once per connection")
  end

  defp handle_enabled(user, %{params: params}) when length(params) < 4 do
    error_and_close(user, "WEBIRC requires at least 4 parameters")
  end

  defp handle_enabled(user, %{params: [password, gateway, hostname, ip | rest]}) do
    with {:ok, gateway_config} <- find_gateway_config(user.ip_address),
         :ok <- validate_password(password, gateway_config),
         {:ok, parsed_ip} <- parse_ip_address(ip),
         :ok <- validate_ip_allowed(parsed_ip),
         :ok <- validate_hostname(hostname, parsed_ip) do
      options = parse_options(rest)
      apply_webirc(user, gateway, hostname, parsed_ip, ip, options)
    else
      {:error, :unauthorized_gateway} ->
        log_failed_attempt(user, "unauthorized gateway")
        error_and_close(user, "Access denied - Unauthorized WebIRC gateway")

      {:error, :invalid_password} ->
        log_failed_attempt(user, "invalid password")
        error_and_close(user, "Access denied - Invalid WebIRC password")

      {:error, :invalid_ip} ->
        log_failed_attempt(user, "invalid IP format")
        error_and_close(user, "Invalid IP address format")

      {:error, :ipv6_not_allowed} ->
        log_failed_attempt(user, "IPv6 not allowed")
        error_and_close(user, "IPv6 addresses are not allowed")

      {:error, :invalid_hostname} ->
        log_failed_attempt(user, "invalid hostname")
        error_and_close(user, "Invalid hostname")
    end
  end

  @spec webirc_enabled?() :: boolean()
  defp webirc_enabled? do
    Application.get_env(:elixircd, :webirc)[:enabled] == true
  end

  @spec find_gateway_config(:inet.ip_address()) :: {:ok, map()} | {:error, :unauthorized_gateway}
  defp find_gateway_config(gateway_ip) do
    gateways = Application.get_env(:elixircd, :webirc)[:gateways] || []

    case Enum.find(gateways, fn gateway ->
           ips = Map.get(gateway, :ips, [])
           ip_in_allowed_list?(gateway_ip, ips)
         end) do
      nil -> {:error, :unauthorized_gateway}
      gateway -> {:ok, gateway}
    end
  end

  @spec ip_in_allowed_list?(:inet.ip_address(), [String.t()]) :: boolean()
  defp ip_in_allowed_list?(ip, allowed_list) do
    Enum.any?(allowed_list, &matches_ip_or_cidr?(ip, &1))
  end

  @spec matches_ip_or_cidr?(:inet.ip_address(), String.t()) :: boolean()
  defp matches_ip_or_cidr?(ip, allowed) do
    if String.contains?(allowed, "/") do
      match_cidr?(ip, allowed)
    else
      case parse_ip_address(allowed) do
        {:ok, allowed_ip} -> ip == allowed_ip
        _ -> false
      end
    end
  end

  @spec match_cidr?(:inet.ip_address(), String.t()) :: boolean()
  defp match_cidr?(ip, cidr) do
    case String.split(cidr, "/") do
      [ip_str, prefix_len_str] ->
        with {:ok, cidr_ip} <- parse_ip_address(ip_str),
             {prefix_len, ""} <- Integer.parse(prefix_len_str) do
          ip_in_cidr?(ip, cidr_ip, prefix_len)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  @spec ip_in_cidr?(:inet.ip_address(), :inet.ip_address(), non_neg_integer()) :: boolean()
  defp ip_in_cidr?({a, b, c, d}, {ca, cb, cc, cd}, prefix_len) when prefix_len <= 32 do
    ip_bits = <<a, b, c, d>>
    cidr_bits = <<ca, cb, cc, cd>>
    match_bits?(ip_bits, cidr_bits, prefix_len)
  end

  defp ip_in_cidr?({a, b, c, d, e, f, g, h}, {ca, cb, cc, cd, ce, cf, cg, ch}, prefix_len)
       when prefix_len <= 128 do
    ip_bits = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    cidr_bits = <<ca::16, cb::16, cc::16, cd::16, ce::16, cf::16, cg::16, ch::16>>
    match_bits?(ip_bits, cidr_bits, prefix_len)
  end

  defp ip_in_cidr?(_, _, _), do: false

  @spec match_bits?(bitstring(), bitstring(), non_neg_integer()) :: boolean()
  defp match_bits?(ip_bits, cidr_bits, prefix_len) do
    <<ip_prefix::bitstring-size(prefix_len), _::bitstring>> = ip_bits
    <<cidr_prefix::bitstring-size(prefix_len), _::bitstring>> = cidr_bits
    ip_prefix == cidr_prefix
  end

  @spec validate_password(String.t(), map()) :: :ok | {:error, :invalid_password}
  defp validate_password(provided_password, gateway_config) do
    expected_password = Map.get(gateway_config, :password)

    if provided_password == expected_password do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  @spec parse_ip_address(String.t()) :: {:ok, :inet.ip_address()} | {:error, :invalid_ip}
  defp parse_ip_address(ip_string) do
    # Handle IPv6 with leading colon
    normalized_ip =
      if String.starts_with?(ip_string, ":") and not String.starts_with?(ip_string, "::") do
        "0" <> ip_string
      else
        ip_string
      end

    case :inet.parse_address(String.to_charlist(normalized_ip)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  @spec validate_ip_allowed(:inet.ip_address()) :: :ok | {:error, :ipv6_not_allowed}
  defp validate_ip_allowed(ip) do
    allow_ipv6 = Application.get_env(:elixircd, :webirc)[:allow_ipv6] != false

    case ip do
      {_, _, _, _} -> :ok
      {_, _, _, _, _, _, _, _} when allow_ipv6 -> :ok
      {_, _, _, _, _, _, _, _} -> {:error, :ipv6_not_allowed}
    end
  end

  @spec validate_hostname(String.t(), :inet.ip_address()) :: :ok | {:error, :invalid_hostname}
  defp validate_hostname(hostname, ip) do
    verify_hostname = Application.get_env(:elixircd, :webirc)[:verify_hostname] == true

    cond do
      # Basic validation: hostname should not be empty
      String.trim(hostname) == "" ->
        {:error, :invalid_hostname}

      # If verification is enabled, do reverse DNS lookup
      verify_hostname ->
        verify_hostname_resolution(hostname, ip)

      # Otherwise, accept the hostname
      true ->
        :ok
    end
  end

  @spec verify_hostname_resolution(String.t(), :inet.ip_address()) :: :ok | {:error, :invalid_hostname}
  defp verify_hostname_resolution(hostname, ip) do
    hostname_charlist = String.to_charlist(hostname)

    case :inet.gethostbyname(hostname_charlist) do
      {:ok, {:hostent, _, _, _, _, addresses}} ->
        if ip in addresses do
          :ok
        else
          {:error, :invalid_hostname}
        end

      {:error, _} ->
        :ok
    end
  end

  @spec parse_options([String.t()]) :: map()
  defp parse_options([]), do: %{}

  defp parse_options([trailing | _]) when is_binary(trailing) do
    trailing
    |> String.split(" ", trim: true)
    |> Enum.reduce(%{}, fn option, acc ->
      case String.split(option, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, unescape_value(value))
        [key] -> Map.put(acc, key, true)
      end
    end)
  end

  @spec unescape_value(String.t()) :: String.t()
  defp unescape_value(value) do
    value
    |> String.replace("\\:", ";")
    |> String.replace("\\s", " ")
    |> String.replace("\\\\", "\\")
    |> String.replace("\\r", "\r")
    |> String.replace("\\n", "\n")
  end

  @spec apply_webirc(User.t(), String.t(), String.t(), :inet.ip_address(), String.t(), map()) :: :ok
  defp apply_webirc(user, gateway_name, hostname, parsed_ip, original_ip, options) do
    secure = Map.get(options, "secure", false)

    Users.update(user, %{
      ip_address: parsed_ip,
      hostname: hostname,
      webirc_gateway: gateway_name,
      webirc_hostname: hostname,
      webirc_ip: original_ip,
      webirc_secure: secure,
      webirc_used: true
    })

    Logger.info("WEBIRC: Gateway '#{gateway_name}' authenticated for #{original_ip} (#{hostname})")

    :ok
  end

  @spec log_failed_attempt(User.t(), String.t()) :: :ok
  defp log_failed_attempt(user, reason) do
    gateway_ip = Network.format_ip_address(user.ip_address)
    Logger.warning("WEBIRC: Failed authentication from #{gateway_ip} - #{reason}")
    :ok
  end

  @spec error_and_close(User.t(), String.t()) :: {:quit, String.t()}
  defp error_and_close(user, message) do
    %Message{command: "ERROR", params: [], trailing: message}
    |> Dispatcher.broadcast(:server, user)

    {:quit, message}
  end
end
