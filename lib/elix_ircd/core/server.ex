defmodule ElixIRCd.Core.Server do
  @moduledoc """
  Module for handling IRC server.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Command
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
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
  Closes the connection for the given user if the socket is open.
  """
  @spec close_connection(user :: Schemas.User.t()) :: :ok
  def close_connection(%{socket: socket, transport: transport}) do
    if is_socket_open?(socket) do
      transport.close(socket)
    end
  end

  # Returns true if the socket is open.
  @spec is_socket_open?(socket :: port()) :: boolean()
  defp is_socket_open?(socket) do
    case :inet.getopts(socket, [:active]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Returns the server name.

  If server name configuration is set, it returns that value, otherwise it returns the hostname.
  """
  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @doc """
  Handles a new socket connection to the server.

  It creates a new user and returns it.
  """
  @spec handle_connect_socket(socket :: port(), transport :: atom()) :: {:ok, Schemas.User.t()} | {:error, String.t()}
  def handle_connect_socket(socket, transport) do
    Logger.debug("New connection: #{inspect(socket)}")

    case Contexts.User.create(%{socket: socket, transport: transport}) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        {:error, "Error creating user: #{inspect(changeset)}"}
    end
  end

  @doc """
  Handles a socket quitting the server.

  If the user exists, it handles the QUIT command, otherwise it does nothing.
  """
  @spec handle_quit_socket(socket :: port(), reason :: String.t()) :: :ok
  def handle_quit_socket(socket, reason) do
    Logger.debug("Connection #{inspect(socket)} terminated: #{inspect(reason)}")

    case Contexts.User.get_by_socket(socket) do
      nil -> :ok
      user -> Command.handle(user, %Message{command: "QUIT", body: reason})
    end
  end
end
