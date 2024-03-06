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
         {:ok, {ident, hostname}} <- handle_identity(user) do
      identity = Helper.build_user_identity(user.nick, user.username, hostname, ident)
      updated_user = Users.update(user, %{ident: ident, hostname: hostname, identity: identity})
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

  @spec handle_identity(User.t()) :: {:ok, {String.t(), String.t()}} | {:error, String.t()}
  defp handle_identity(user) do
    ident_task = Task.async(fn -> check_ident(user) end)
    hostname_task = Task.async(fn -> lookup_hostname(user.socket) end)
    ident_result = Task.await(ident_task)
    hostname_result = Task.await(hostname_task)

    case hostname_result do
      {:ok, hostname} ->
        {:ok, {ident_result, hostname}}

      {:error, error} ->
        {:error, error}
    end
  end

  # TODO
  defp check_ident(_user) do
    nil
  end

  @spec lookup_hostname(socket :: :inet.socket()) :: {:ok, String.t()} | {:error, String.t()}
  defp lookup_hostname(socket) do
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

  # # # Call the IdentClient.request_ident function
  # # case IdentClient.request_ident(6667, 113, {127, 0, 0, 1}) do
  # #   {:ok, userid} ->
  # #     IO.puts("Received user ID from Ident service: #{userid}")
  # #   {:error, reason} ->
  # #     IO.puts("Failed to receive user ID from Ident service. Reason: #{inspect(reason)}")
  # # end
  # defp request_ident(user_port, server_port, client_ip) do
  #   # Open a connection to the client's Ident service on port 113
  #   with {:ok, socket} <- :gen_tcp.connect({client_ip, 0, user_port}, 113, [:binary, active: false]),
  #        # Formulate the Ident query
  #        query = "#{user_port}, #{server_port}\n",
  #        # Send the Ident query to the client
  #        :ok <- :gen_tcp.send(socket, query),
  #        # Wait for the response from the client
  #        {:ok, response} <- :gen_tcp.recv(socket, 0, 5000) do
  #     # Close the connection
  #     :ok = :gen_tcp.close(socket)

  #     # Process and return the response
  #     # Parses the Ident response and extracts the identity information
  #     case String.split(response, ":") do
  #       [_, " USERID ", _, userid] ->
  #         {:ok, String.trim(userid)}

  #       _ ->
  #         {:error, :invalid_response}
  #     end
  #   else
  #     _error ->
  #       # Handle errors such as connection failures or timeouts
  #       Logger.error("Failed to query Ident service at #{client_ip}:113")
  #       {:error, :request_failed}
  #   end
  # end
end
