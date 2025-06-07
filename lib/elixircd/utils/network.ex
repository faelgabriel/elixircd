defmodule ElixIRCd.Utils.Network do
  @moduledoc """
  Module for utility functions related to the network.
  """

  @doc """
  Looks up the hostname for an IP address.
  """
  @spec lookup_hostname(ip_address :: :inet.ip_address()) :: {:ok, String.t()} | {:error, String.t()}
  def lookup_hostname(ip_address) do
    case :inet.gethostbyaddr(ip_address) do
      {:ok, {:hostent, hostname, _, _, _, _}} -> {:ok, to_string(hostname)}
      {:error, error} -> {:error, "Unable to get hostname for #{inspect(ip_address)}: #{inspect(error)}"}
    end
  end

  @doc """
  Formats an IP address.
  """
  @spec format_ip_address(ip_address :: :inet.ip_address()) :: String.t()
  def format_ip_address({a, b, c, d}) do
    [a, b, c, d]
    |> Enum.map_join(".", &Integer.to_string/1)
  end

  def format_ip_address({a, b, c, d, e, f, g, h}) do
    formatted_ip =
      [a, b, c, d, e, f, g, h]
      |> Enum.map_join(":", &Integer.to_string(&1, 16))

    Regex.replace(~r/\b:?(?:0+:?){2,}/, formatted_ip, "::", global: false)
  end

  @doc """
  Retrieves the user identifier from an Ident server.
  """
  # Mimic library does not support mocking of sticky modules (e.g. :gen_tcp),
  # we need to ignore this module from the test coverage for now.
  # coveralls-ignore-start
  @spec query_identd(:inet.ip_address(), integer()) :: {:ok, String.t()} | {:error, String.t()}
  def query_identd(ip_address, irc_server_port) do
    timeout = Application.get_env(:elixircd, :ident_service)[:timeout]

    with {:ok, socket} <- :gen_tcp.connect(ip_address, 113, [:binary, {:active, false}], timeout),
         :ok <- :gen_tcp.send(socket, "#{irc_server_port}, 113\r\n"),
         {:ok, data} <- :gen_tcp.recv(socket, 0, timeout),
         :ok <- :gen_tcp.close(socket),
         [_port_info, "USERID", _os, user_id] <- String.split(data, " : ", trim: true) do
      {:ok, user_id}
    else
      {:error, reason} -> {:error, "Failed to retrieve Identd response: #{inspect(reason)}"}
      data -> {:error, "Unexpected Identd response: #{inspect(data)}"}
    end
  end

  # coveralls-ignore-stop
end
