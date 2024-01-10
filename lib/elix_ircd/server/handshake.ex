defmodule ElixIRCd.Server.Handshake do
  @moduledoc """
  Module for handling IRC server handshake.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  require Logger

  @doc """
  Handles the user handshake.
  """
  @spec handle(Schemas.User.t()) :: :ok
  def handle(user) when user.nick != nil and user.username != nil and user.realname != nil do
    case handle_lookup_hostname(user) do
      {:ok, user} -> handle_motd(user)
      error -> Logger.error("Error looking up hostname for user #{inspect(user)}: #{inspect(error)}")
    end
  end

  def handle(_user), do: :ok

  @spec handle_lookup_hostname(Schemas.User.t()) :: {:ok, Schemas.User.t()} | {:error, Changeset.t()}
  defp handle_lookup_hostname(user) do
    hostname = get_socket_hostname(user.socket)
    identity = "#{user.nick}!#{String.slice(user.username, 0..7)}@#{hostname}"
    Contexts.User.update(user, %{hostname: hostname, identity: identity})
  end

  @spec handle_motd(Schemas.User.t()) :: :ok
  defp handle_motd(user) do
    server_name = Application.get_env(:elixircd, :server_name)

    [
      Message.new(%{
        source: :server,
        command: :rpl_welcome,
        params: [user.nick],
        body: "Welcome to the #{server_name} Internet Relay Chat Network #{user.nick}"
      }),
      Message.new(%{
        source: :server,
        command: :rpl_yourhost,
        params: [user.nick],
        body: "Your host is #{server_name}, running version 0.1.0."
      }),
      Message.new(%{
        source: :server,
        command: :rpl_created,
        params: [user.nick],
        body: "This server was created #{DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()}"
      }),
      Message.new(%{source: :server, command: :rpl_myinfo, params: [user.nick], body: "ElixIRCd 0.1.0 +i +int"}),
      Message.new(%{source: :server, command: :rpl_endofmotd, params: [user.nick], body: "End of MOTD command"})
    ]
    |> Server.send_messages(user)

    :ok
  end

  @spec get_socket_hostname(socket :: :inet.socket()) :: String.t()
  defp get_socket_hostname(socket) do
    case get_socket_ip(socket) do
      {:ok, ip} ->
        case :inet.gethostbyaddr(ip) do
          {:ok, {:hostent, hostname, _, _, _, _}} ->
            to_string(hostname)

          _ ->
            formatted_ip = format_ip_address(ip)
            Logger.info("Could not resolve hostname for #{formatted_ip}. Using IP instead.")
            formatted_ip
        end
    end
  end

  @spec get_socket_ip(socket :: :inet.socket()) :: {:ok, tuple()} | {:error, any()}
  defp get_socket_ip(socket) do
    case :inet.peername(Helper.extract_port_socket(socket)) do
      {:ok, {ip, _port}} -> {:ok, ip}
      {:error, error} -> {:error, error}
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
