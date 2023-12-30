defmodule ElixIRCd.Core.Server do
  @moduledoc """
  Module for handling IRC server.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Command
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder
  alias ElixIRCd.Message.MessageParser
  alias ElixIRCd.Types.SocketType

  require Logger

  @doc """
  Handles a new socket connection to the server.
  """
  @spec handle_connect(socket :: :inet.socket(), transport :: atom(), pid :: pid()) ::
          {:ok, Schemas.User.t()} | {:error, String.t()}
  def handle_connect(socket, transport, pid) do
    Logger.debug("New connection: #{inspect(socket)}")

    case Contexts.User.create(%{socket: socket, transport: transport, pid: pid}) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, "Error creating user: #{inspect(changeset)}"}
    end
  end

  @doc """
  Handles a socket disconnection from the server.
  """
  @spec handle_disconnect(socket :: :inet.socket(), transport :: atom(), reason :: String.t()) :: :ok
  def handle_disconnect(socket, transport, reason) do
    Logger.debug("Connection #{inspect(socket)} terminated: #{inspect(reason)}")

    if is_socket_connected?(socket), do: transport.close(socket)

    case Contexts.User.get_by_socket(socket) do
      {:error, _} -> :ok
      {:ok, user} -> handle_user_quit(user, reason)
    end
  end

  @doc """
  Handles a packet data from the given socket.
  """
  @spec handle_packet(socket :: :inet.socket(), data :: String.t()) :: :ok
  def handle_packet(socket, data) do
    message = String.trim_trailing(data)
    Logger.debug("<- #{inspect(message)}")

    with {:ok, user} <- Contexts.User.get_by_socket(socket),
         {:ok, message} <- MessageParser.parse(message),
         :ok <- Command.handle(user, message) do
      :ok
    else
      {:error, error} -> Logger.error("Error handling message #{inspect(message)}: #{inspect(error)}")
    end
  end

  @doc """
  Extracts the raw socket from the given socket.
  """
  @spec extract_port_socket(SocketType.t()) :: port()
  def extract_port_socket(socket) when is_port(socket), do: socket
  def extract_port_socket({:sslsocket, {:gen_tcp, socket, :tls_connection, _}, _}), do: socket

  @doc """
  Sends a packet data to the given user.
  """
  @spec send_packet(user :: Schemas.User.t(), message :: String.t()) :: :ok
  def send_packet(%{socket: socket, transport: transport}, message) do
    Logger.debug("-> #{inspect(message)}")
    transport.send(socket, message <> "\r\n")
  end

  @doc """
  Returns the server name.
  """
  @spec server_name() :: String.t()
  def server_name, do: Application.get_env(:elixircd, :server_name)

  @doc """
  Returns the server hostname.
  """
  @spec server_hostname() :: String.t()
  def server_hostname, do: Application.get_env(:elixircd, :server_hostname)

  @spec get_socket_hostname(socket :: :inet.socket()) :: String.t()
  def get_socket_hostname(socket) do
    case get_socket_ip(socket) do
      {:ok, ip} ->
        case :inet.gethostbyaddr(ip) do
          {:ok, {:hostent, hostname, _, _, _, _}} ->
            to_string(hostname)

          _ ->
            formatted_ip = format_ip(ip)
            Logger.info("Could not resolve hostname for #{formatted_ip}. Using IP instead.")
            formatted_ip
        end
    end
  end

  @spec get_socket_ip(socket :: :inet.socket()) :: {:ok, tuple()} | {:error, any()}
  defp get_socket_ip(socket) when is_port(socket) do
    case :inet.peername(socket) do
      {:ok, {ip, _port}} -> {:ok, ip}
      {:error, error} -> {:error, error}
    end
  end

  defp get_socket_ip({:sslsocket, {:gen_tcp, socket, :tls_connection, _}, _}), do: get_socket_ip(socket)

  @spec format_ip(ip :: tuple()) :: String.t()
  defp format_ip({a, b, c, d}) do
    [a, b, c, d]
    |> Enum.map_join(".", &Integer.to_string/1)
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    formatted_ip =
      [a, b, c, d, e, f, g, h]
      |> Enum.map_join(":", &Integer.to_string(&1, 16))

    Regex.replace(~r/\b:?(?:0+:?){2,}/, formatted_ip, "::", global: false)
  end

  @spec is_socket_connected?(socket :: :inet.socket()) :: boolean()
  defp is_socket_connected?(socket) when is_port(socket) do
    case :inet.peername(socket) do
      {:ok, _peer} -> true
      {:error, _} -> false
    end
  end

  defp is_socket_connected?({:sslsocket, {:gen_tcp, socket, :tls_connection, _}, _}), do: is_socket_connected?(socket)

  @spec handle_user_quit(user :: Schemas.User.t(), quit_message :: String.t()) :: :ok
  defp handle_user_quit(user, quit_message) do
    user_channels = Contexts.UserChannel.get_by_user(user)

    # All users in all channels the user is in
    all_channel_users =
      Enum.reduce(user_channels, [], fn %Schemas.UserChannel{} = user_channel, acc ->
        channel_users = Contexts.UserChannel.get_by_channel(user_channel.channel) |> Enum.map(& &1.user)
        acc ++ channel_users
      end)
      |> Enum.uniq()
      |> Enum.reject(fn x -> x == user end)

    MessageBuilder.user_message(user.identity, "QUIT", [], quit_message)
    |> Messaging.send_message(all_channel_users)

    # Delete the user and all its associated user channels
    with _ <- Contexts.UserChannel.delete_all(user_channels),
         {:ok, _} <- Contexts.User.delete(user) do
      :ok
    else
      {:error, changeset} -> Logger.error("Error deleting user #{inspect(user)}: #{inspect(changeset)}")
    end
  end
end
