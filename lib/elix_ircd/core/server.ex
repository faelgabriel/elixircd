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
  Handles a new socket connection to the server.
  """
  @spec handle_connect(socket :: port(), transport :: atom(), pid :: pid()) ::
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
  @spec handle_disconnect(socket :: port(), transport :: atom(), reason :: String.t()) :: :ok
  def handle_disconnect(socket, transport, reason) do
    Logger.debug("Connection #{inspect(socket)} terminated: #{inspect(reason)}")

    if is_socket_open?(socket), do: transport.close(socket)

    case Contexts.User.get_by_socket(socket) do
      {:error, _} -> :ok
      {:ok, user} -> handle_user_quit(user, reason)
    end
  end

  @doc """
  Handles a packet data from the given socket.
  """
  @spec handle_packet(socket :: port(), data :: String.t()) :: :ok
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
  def server_name, do: @server_name

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

    # All users in all channels the user is in
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

    # Delete the user and all its associated user channels
    case Contexts.User.delete(user) do
      {:ok, _} -> :ok
      {:error, changeset} -> Logger.error("Error deleting user #{inspect(user)}: #{inspect(changeset)}")
    end
  end
end
