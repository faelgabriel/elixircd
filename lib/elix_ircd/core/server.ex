defmodule ElixIRCd.Core.Server do
  @moduledoc """
  Module for handling IRC server.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Command
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder
  alias ElixIRCd.Message.MessageParser

  require Logger

  @server_name Application.compile_env(:elixircd, :server)[:name] || :inet.gethostname() |> elem(1) |> to_string()

  @doc """
  Handles TCP streams and buffers the data until a complete message is received.
  """
  @spec handle_stream(socket :: port(), buffer :: String.t(), data :: String.t()) :: String.t()
  def handle_stream(socket, buffer, data) do
    {complete_messages, remainder_buffer} = extract_messages(buffer <> data)

    Enum.each(complete_messages, fn message ->
      handle_message(socket, message)
    end)

    remainder_buffer
  end

  # Extracts complete messages from the buffer and returns the remaining buffer.
  @spec extract_messages(buffer :: String.t()) :: {[String.t()], String.t()}
  defp extract_messages(buffer) do
    parts = String.split(buffer, "\r\n")

    case Enum.reverse(parts) do
      [last | rest] -> {Enum.reverse(rest), last}
      [] -> {[], ""}
    end
  end

  # Handles a single message from a incoming stream.
  @spec handle_message(socket :: port(), message :: String.t()) :: :ok | :error
  defp handle_message(socket, message) do
    Logger.debug("<- #{inspect(message)}")

    with {:ok, user} <- handle_user(socket),
         {:ok, message} <- MessageParser.parse(message),
         :ok <- Command.handle(user, message) do
      :ok
    else
      error ->
        Logger.error("Error handling message #{inspect(message)}: #{inspect(error)}")
        :error
    end
  end

  # Returns the user for the given socket.
  @spec handle_user(socket :: port()) :: {:ok, Schemas.User.t()} | {:error, String.t()}
  defp handle_user(socket) do
    case Contexts.User.get_by_socket(socket) do
      nil ->
        {:error, "Could not find user for socket #{socket}."}

      user ->
        {:ok, user}
    end
  end

  @doc """
  Sends a packet to the given user.
  """
  @spec send_packet(user :: Schemas.User.t(), message :: String.t()) :: :ok
  def send_packet(%{socket: socket, transport: transport}, message) do
    Logger.debug("-> #{inspect(message)}")
    transport.send(socket, message <> "\r\n")
  end

  @doc """
  Returns the server name.

  The server name is the hostname of the server, or the custom name configured in the config file.
  """
  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @doc """
  Handles a new socket connection to the server.

  It registers the socket in the registry and creates a new user.
  """
  @spec handle_connect_socket(socket :: port(), transport :: atom(), pid :: pid()) ::
          {:ok, Schemas.User.t()} | {:error, String.t()}
  def handle_connect_socket(socket, transport, pid) do
    Logger.debug("New connection: #{inspect(socket)}")

    Registry.register(ElixIRCd.Protocols.Registry, socket, pid)

    case Contexts.User.create(%{socket: socket, transport: transport}) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        {:error, "Error creating user: #{inspect(changeset)}"}
    end
  end

  @doc """
  Handles a socket connection quitting the server.

  It closes the socket and unregisters the socket from the registry.
  If the socket is associated with a user, it handles the user quitting the server.
  """
  @spec handle_quit_socket(socket :: port(), transport :: atom(), reason :: String.t()) :: :ok
  def handle_quit_socket(socket, transport, reason) do
    Logger.debug("Connection #{inspect(socket)} terminated: #{inspect(reason)}")

    if is_socket_open?(socket), do: transport.close(socket)

    Registry.unregister(ElixIRCd.Protocols.Registry, socket)

    case Contexts.User.get_by_socket(socket) do
      nil -> :ok
      user -> handle_user_quit(user, reason)
    end
  end

  @spec is_socket_open?(socket :: port()) :: boolean()
  defp is_socket_open?(socket) do
    case :inet.getopts(socket, [:active]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @spec handle_user_quit(user :: Schemas.User.t(), quit_message :: String.t()) :: :ok
  defp handle_user_quit(user, quit_message) do
    user_channels = Contexts.UserChannel.get_by_user(user)

    all_channel_users =
      Enum.reduce(user_channels, [], fn %Schemas.UserChannel{} = user_channel, acc ->
        channel = user_channel.channel |> Repo.preload(user_channels: :user)
        channel_users = channel.user_channels |> Enum.map(& &1.user)
        acc ++ channel_users
      end)
      |> Enum.uniq()
      |> Enum.reject(fn x -> x == user end)

    MessageBuilder.user_message(user.identity, "QUIT", [], quit_message)
    |> Messaging.send_message(all_channel_users)

    # Delete the user and all associated user channels
    Contexts.User.delete(user)
  end
end
