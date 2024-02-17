defmodule ElixIRCd.Server.Handshake do
  @moduledoc """
  Module for handling IRC server handshake for users.
  """

  require Logger

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @doc """
  Handles the user handshake.

  This should be called around a transaction.
  The `user` should be loaded in the same transaction.
  """
  @spec handle(User.t()) :: :ok
  def handle(user) when user.nick != nil and user.username != nil and user.realname != nil do
    with {:ok, hostname} <- resolve_hostname(user.socket),
         user_identity <- build_user_identity(user.nick, user.username, hostname),
         updated_user <- Users.update(user, %{hostname: hostname, identity: user_identity}) do
      handle_motd(updated_user)
    else
      {:error, error} ->
        Logger.critical("Error handling handshake for user #{inspect(user)}: #{inspect(error)}")
        :ok
    end
  end

  def handle(_user), do: :ok

  @spec build_user_identity(String.t(), String.t(), String.t()) :: String.t()
  def build_user_identity(nick, username, hostname), do: "#{nick}!#{String.slice(username, 0..7)}@#{hostname}"

  @spec handle_motd(User.t()) :: :ok
  defp handle_motd(user) do
    server_name = Application.get_env(:elixircd, :server_name)

    [
      Message.build(%{
        prefix: :server,
        command: :rpl_welcome,
        params: [user.nick],
        trailing: "Welcome to the #{server_name} Internet Relay Chat Network #{user.nick}"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_yourhost,
        params: [user.nick],
        trailing: "Your host is #{server_name}, running version 0.1.0."
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_created,
        params: [user.nick],
        trailing: "This server was created #{DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()}"
      }),
      Message.build(%{prefix: :server, command: :rpl_myinfo, params: [user.nick], trailing: "ElixIRCd 0.1.0 +i +int"}),
      Message.build(%{prefix: :server, command: :rpl_endofmotd, params: [user.nick], trailing: "End of MOTD command"})
    ]
    |> Messaging.broadcast(user)

    :ok
  end

  @spec resolve_hostname(socket :: :inet.socket()) :: {:ok, String.t()} | {:error, String.t()}
  defp resolve_hostname(socket) do
    case Helper.get_socket_ip(socket) do
      {:ok, ip} ->
        case Helper.get_socket_hostname(ip) do
          {:ok, hostname} ->
            {:ok, hostname}

          _ ->
            formatted_ip = format_ip_address(ip)
            Logger.debug("Could not resolve hostname for #{formatted_ip}. Using IP instead.")
            {:ok, formatted_ip}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @spec format_ip_address(ip_address :: tuple()) :: String.t()
  defp format_ip_address({a, b, c, d}) do
    [a, b, c, d]
    |> Enum.map_join(".", &Integer.to_string/1)
  end

  defp format_ip_address({a, b, c, d, e, f, g, h}) do
    formatted_ip =
      [a, b, c, d, e, f, g, h]
      |> Enum.map_join(":", &Integer.to_string(&1, 16))

    Regex.replace(~r/\b:?(?:0+:?){2,}/, formatted_ip, "::", global: false)
  end
end
