defmodule ElixIRCd.Server.Handshake do
  @moduledoc """
  Module for handling IRC server handshake for users.
  """

  require Logger

  alias ElixIRCd.Command.Motd
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
    with :ok <- check_server_password(user),
         {:ok, hostname} <- resolve_hostname(user.socket),
         updated_user <- Users.update(user, %{registered: true, hostname: hostname}) do
      Motd.send_motd(updated_user)
    else
      {:error, :bad_password} ->
        Message.build(%{prefix: :server, command: :err_passwdmismatch, params: ["*"], trailing: "Bad Password"})
        |> Messaging.broadcast(user)

        {:quit, "Bad Password"}

      {:error, error} ->
        Logger.debug("User handshake failed for #{inspect(user)}: #{error}")
        {:quit, "Handshake Failed"}
    end
  end

  def handle(_user), do: :ok

  @spec check_server_password(User.t()) :: :ok | {:error, :bad_password}
  defp check_server_password(%User{password: password}) do
    case Application.get_env(:elixircd, :server_password) do
      nil -> :ok
      server_password when server_password != password -> {:error, :bad_password}
      _ -> :ok
    end
  end

  @spec resolve_hostname(socket :: :inet.socket()) :: {:ok, String.t()} | {:error, String.t()}
  defp resolve_hostname(socket) do
    case Helper.get_socket_ip(socket) do
      {:ok, ip} -> {:ok, resolve_hostname_from_ip(ip)}
      {:error, _} = error -> error
    end
  end

  @spec resolve_hostname_from_ip(ip :: tuple()) :: String.t()
  defp resolve_hostname_from_ip(ip) do
    formatted_ip = format_ip_address(ip)

    case Helper.get_socket_hostname(ip) do
      {:ok, hostname} ->
        Logger.debug("Resolved hostname for #{formatted_ip}: #{hostname}")
        hostname

      _ ->
        Logger.debug("Could not resolve hostname for #{formatted_ip}")
        formatted_ip
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
