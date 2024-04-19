defmodule ElixIRCd.Server.Handshake do
  @moduledoc """
  Module for handling IRC server handshake for users.
  """

  require Logger

  import ElixIRCd.Helper,
    only: [format_ip_address: 1, get_socket_hostname: 1, get_socket_ip: 1, get_socket_port_connected: 1]

  alias ElixIRCd.Command.Motd
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Handshake.IdentClient
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
         {:ok, {userid, hostname}} <- handle_async_data(user) do
      updated_user =
        Users.update(user, %{
          userid: userid,
          hostname: hostname,
          registered: true,
          registered_at: DateTime.utc_now()
        })

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
    case Application.get_env(:elixircd, :server)[:password] do
      nil -> :ok
      server_password when server_password != password -> {:error, :bad_password}
      _ -> :ok
    end
  end

  @spec handle_async_data(User.t()) :: {:ok, {String.t(), String.t()}} | {:error, String.t()}
  defp handle_async_data(user) do
    ident_task = Task.async(fn -> check_ident(user) end)
    hostname_task = Task.async(fn -> lookup_hostname(user) end)
    ident_result = Task.await(ident_task)
    hostname_result = Task.await(hostname_task)

    case hostname_result do
      {:ok, hostname} -> {:ok, {ident_result, hostname}}
      {:error, error} -> {:error, error}
    end
  end

  @spec check_ident(User.t()) :: String.t() | nil
  defp check_ident(user) do
    with true <- Application.get_env(:elixircd, :ident_service)[:enabled],
         {:ok, ip} <- get_socket_ip(user.socket),
         {:ok, port_connected} <- get_socket_port_connected(user.socket) do
      request_ident(user, ip, port_connected)
    else
      _error -> nil
    end
  end

  @spec request_ident(user :: User.t(), ip_address :: tuple(), port_connected :: integer()) :: String.t() | nil
  defp request_ident(user, ip, port_connected) do
    Message.build(%{prefix: :server, command: "NOTICE", params: ["*"], trailing: "*** Checking Ident"})
    |> Messaging.broadcast(user)

    IdentClient.query_userid(ip, port_connected)
    |> case do
      {:ok, user_id} ->
        Message.build(%{prefix: :server, command: "NOTICE", params: ["*"], trailing: "*** Got Ident response"})
        |> Messaging.broadcast(user)

        user_id

      {:error, _} ->
        Message.build(%{prefix: :server, command: "NOTICE", params: ["*"], trailing: "*** No Ident response"})
        |> Messaging.broadcast(user)

        nil
    end
  end

  @spec lookup_hostname(User.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp lookup_hostname(user) do
    case get_socket_ip(user.socket) do
      {:ok, ip} -> {:ok, resolve_hostname(user, ip)}
      error -> error
    end
  end

  @spec resolve_hostname(user :: User.t(), ip_address :: tuple()) :: String.t()
  defp resolve_hostname(user, ip_address) do
    Message.build(%{prefix: :server, command: "NOTICE", params: ["*"], trailing: "*** Looking up your hostname..."})
    |> Messaging.broadcast(user)

    formatted_ip_address = format_ip_address(ip_address)

    case get_socket_hostname(ip_address) do
      {:ok, hostname} ->
        Logger.debug("Resolved hostname for #{formatted_ip_address}: #{hostname}")

        Message.build(%{prefix: :server, command: "NOTICE", params: ["*"], trailing: "*** Found your hostname"})
        |> Messaging.broadcast(user)

        hostname

      _error ->
        Logger.debug("Could not resolve hostname for #{formatted_ip_address}")

        Message.build(%{
          prefix: :server,
          command: "NOTICE",
          params: ["*"],
          trailing: "*** Couldn't look up your hostname"
        })
        |> Messaging.broadcast(user)

        formatted_ip_address
    end
  end
end
