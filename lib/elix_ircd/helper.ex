defmodule ElixIRCd.Helper do
  @moduledoc """
  Module for helper functions.
  """

  alias ElixIRCd.Data.Schemas

  @doc """
  Determines if a target is a channel name.
  """
  @spec is_channel_name?(String.t()) :: boolean()
  def is_channel_name?(target) do
    String.starts_with?(target, "#") ||
      String.starts_with?(target, "&") ||
      String.starts_with?(target, "+") ||
      String.starts_with?(target, "!")
  end

  @doc """
  Checks if a socket is connected.
  """
  @spec is_socket_connected?(socket :: :inet.socket()) :: boolean()
  def is_socket_connected?(socket) do
    case :inet.peername(get_socket_port(socket)) do
      {:ok, _peer} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Gets the reply for a user's identity.
  """
  @spec get_user_reply(Schemas.User.t()) :: String.t()
  def get_user_reply(%{identity: nil}), do: "*"
  def get_user_reply(%{nick: nick}), do: nick

  @doc """
  Gets a list of targets from a comma-separated string.
  """
  @spec get_target_list(String.t()) :: {:channels, [String.t()]} | {:users, [String.t()]} | {:error, String.t()}
  def get_target_list(targets) do
    list_targets =
      targets
      |> String.split(",")

    cond do
      Enum.all?(list_targets, &is_channel_name?/1) ->
        {:channels, list_targets}

      Enum.all?(list_targets, fn target -> !is_channel_name?(target) end) ->
        {:users, list_targets}

      true ->
        {:error, "Invalid list of targets"}
    end
  end

  @doc """
  Gets the hostname for an IP address.
  """
  @spec get_socket_hostname(ip :: tuple()) :: {:ok, String.t()} | {:error, String.t()}
  def get_socket_hostname(ip) do
    case :inet.gethostbyaddr(ip) do
      {:ok, {:hostent, hostname, _, _, _, _}} -> {:ok, to_string(hostname)}
      {:error, error} -> {:error, "Unable to get hostname for #{inspect(ip)}: #{inspect(error)}"}
    end
  end

  @doc """
  Gets the IP address for a socket.
  """
  @spec get_socket_ip(socket :: :inet.socket()) :: {:ok, tuple()} | {:error, String.t()}
  def get_socket_ip(socket) do
    case :inet.peername(get_socket_port(socket)) do
      {:ok, {ip, _port}} -> {:ok, ip}
      {:error, error} -> {:error, "Unable to get IP for #{inspect(socket)}: #{inspect(error)}"}
    end
  end

  @doc """
  Gets the port for a socket.
  """
  @spec get_socket_port(:inet.socket()) :: port()
  def get_socket_port(socket) when is_port(socket), do: socket
  def get_socket_port({:sslsocket, {:gen_tcp, socket, :tls_connection, _}, _}), do: socket
end
