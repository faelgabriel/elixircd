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
  @spec query_identd(:inet.ip_address(), :inet.port_number(), :inet.port_number()) ::
          {:ok, String.t()} | {:error, String.t()}
  def query_identd(ip_address, client_port, irc_server_port) do
    timeout = Application.fetch_env!(:elixircd, :ident_service)[:timeout]

    case :gen_tcp.connect(ip_address, 113, [:binary, active: false, packet: :line, packet_size: 1024], timeout) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, format_ident_query(client_port, irc_server_port)),
               {:ok, data} <- :gen_tcp.recv(socket, 0, timeout) do
            parse_ident_response(data, client_port, irc_server_port)
          else
            {:error, reason} -> {:error, "Failed to retrieve Identd response: #{inspect(reason)}"}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, "Failed to connect to Identd: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec format_ident_query(:inet.port_number(), :inet.port_number()) :: String.t()
  def format_ident_query(client_port, irc_server_port), do: "#{client_port}, #{irc_server_port}\r\n"

  @doc false
  @spec parse_ident_response(binary(), :inet.port_number(), :inet.port_number()) ::
          {:ok, String.t()} | {:error, String.t()}
  def parse_ident_response(data, client_port, irc_server_port) do
    pattern =
      ~r/\A[ \t]*(\d{1,5})[ \t]*,[ \t]*(\d{1,5})[ \t]*:[ \t]*USERID[ \t]*:[ \t]*[^:\r\n]+:[ \t]*([A-Za-z0-9_~-]+)\r\n\z/

    case Regex.run(pattern, data) do
      [_, response_client_port, response_server_port, user_id] ->
        max_length = Application.fetch_env!(:elixircd, :user)[:max_ident_length]

        if String.to_integer(response_client_port) == client_port and
             String.to_integer(response_server_port) == irc_server_port and byte_size(user_id) <= max_length do
          {:ok, user_id}
        else
          {:error, "Unexpected Identd response"}
        end

      _ ->
        {:error, "Unexpected Identd response"}
    end
  end

  # coveralls-ignore-stop
end
