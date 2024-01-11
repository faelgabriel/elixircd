defmodule ElixIRCd.Server do
  @moduledoc """
  Module for the server protocol.
  """

  alias ElixIRCd.Command
  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message

  require Logger

  @behaviour :ranch_protocol
  @timeout 180_000
  @reuseaddr Mix.env() in [:dev, :test]

  @doc """
  Starts a linked user connection process for the SSL server protocol.

  This function initializes the SSL server process and links it to the calling process.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module (:ranch_tcp or :ranch_ssl).
  - `opts`: Options for the server.

  ## Returns
  - `{:ok, pid}` on successful start of the process.
  """
  @spec start_link(ref :: pid(), transport :: module(), opts :: keyword()) :: {:ok, pid()}
  def start_link(ref, transport, opts) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, opts])}
  end

  @doc """
  Initializes the SSL server after a connection is established.

  This function is called after a successful connection is established to initialize the server.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module.
  - `_opts`: Options for the server (currently not in use).

  ## Returns
  - `:ok` if the connection is successfully handled.
  - `:error` in case of an error.
  """
  @spec init(ref :: pid(), transport :: atom(), _opts :: keyword()) :: :ok | :error
  def init(ref, transport, _opts) do
    with {:ok, socket} <- :ranch.handshake(ref),
         {:ok, _new_user} <- handle_connect(socket, transport, self()) do
      transport.setopts(socket, [
        {:packet, :line},
        {:reuseaddr, @reuseaddr}
      ])

      connection_loop(socket, transport)
    else
      {:continue, reason} ->
        Logger.error("SSL Handshake Error: #{inspect(reason)}")
        :error

      {:error, reason} ->
        Logger.error("Server Error: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Sends a message to the given user or users.
  """
  @spec send_message(Message.t(), Schemas.User.t() | [Schemas.User.t()]) :: :ok
  def send_message(message, user_or_users), do: send_messages([message], user_or_users)

  @doc """
  Sends multiple messages to the given user or users.
  """
  @spec send_messages([Message.t()], Schemas.User.t() | [Schemas.User.t()]) :: :ok
  def send_messages(messages, %Schemas.User{} = user), do: send_messages(messages, [user])

  def send_messages(messages, users) do
    Enum.each(messages, fn message ->
      raw_message = Message.unparse!(message)

      Enum.each(users, fn user ->
        send_packet(user, raw_message)
      end)
    end)

    :ok
  end

  # Continuously processes incoming data on the server.
  # This function is the main loop of the server, handling incoming data and managing the socket's state.
  @spec connection_loop(:inet.socket(), atom()) :: :ok
  defp connection_loop(socket, transport) do
    transport.setopts(socket, active: :once)

    receive do
      {:tcp, ^socket, data} ->
        handle_packet(socket, data)
        connection_loop(socket, transport)

      {:ssl, ^socket, data} ->
        handle_packet(socket, data)
        connection_loop(socket, transport)

      {:tcp_closed, ^socket} ->
        handle_disconnect(socket, transport, "Connection Closed")

      {:ssl_closed, ^socket} ->
        handle_disconnect(socket, transport, "Connection Closed")

      {:tcp_error, ^socket, reason} ->
        handle_disconnect(socket, transport, "Connection Error: #{reason}")

      {:ssl_error, ^socket, reason} ->
        handle_disconnect(socket, transport, "Connection Error: #{reason}")

      {:user_quit, ^socket, reason} ->
        handle_disconnect(socket, transport, reason)
    after
      @timeout ->
        handle_disconnect(socket, transport, "Connection Timeout")
    end
  end

  @spec handle_connect(socket :: :inet.socket(), transport :: atom(), pid :: pid()) ::
          {:ok, Schemas.User.t()} | {:error, String.t()}
  defp handle_connect(socket, transport, pid) do
    Logger.debug("New connection: #{inspect(socket)}")

    case Contexts.User.create(%{socket: socket, transport: transport, pid: pid}) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, "Error creating user: #{inspect(changeset)}"}
    end
  end

  @spec handle_disconnect(socket :: :inet.socket(), transport :: atom(), reason :: String.t()) :: :ok
  defp handle_disconnect(socket, transport, reason) do
    Logger.debug("Connection #{inspect(socket)} terminated: #{inspect(reason)}")

    if Helper.is_socket_connected?(socket), do: transport.close(socket)

    case Contexts.User.get_by_socket(socket) do
      {:error, _} -> :ok
      {:ok, user} -> handle_user_quit(user, reason)
    end
  end

  @spec handle_packet(socket :: :inet.socket(), data :: String.t()) :: :ok
  defp handle_packet(socket, data) do
    message = String.trim_trailing(data)
    Logger.debug("<- #{inspect(message)}")

    with {:ok, user} <- Contexts.User.get_by_socket(socket),
         {:ok, message} <- Message.parse(message),
         :ok <- Command.handle(user, message) do
      :ok
    else
      {:error, error} -> Logger.error("Error handling message #{inspect(message)}: #{inspect(error)}")
    end
  end

  @spec send_packet(user :: Schemas.User.t(), message :: String.t()) :: :ok
  defp send_packet(%{socket: socket, transport: transport}, message) do
    Logger.debug("-> #{inspect(message)}")
    transport.send(socket, message <> "\r\n")
  end

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

    Message.new(%{source: user.identity, command: "QUIT", params: [], body: quit_message})
    |> send_message(all_channel_users)

    # Delete the user and all its associated user channels
    with _ <- Contexts.UserChannel.delete_all(user_channels),
         {:ok, _} <- Contexts.User.delete(user) do
      :ok
    else
      {:error, changeset} -> Logger.error("Error deleting user #{inspect(user)}: #{inspect(changeset)}")
    end
  end
end
