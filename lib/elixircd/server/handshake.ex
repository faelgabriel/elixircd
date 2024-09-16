defmodule ElixIRCd.Server.Handshake do
  @moduledoc """
  Module for handling IRC server handshake for users.
  """

  require Logger

  import ElixIRCd.Helper,
    only: [format_ip_address: 1, get_socket_hostname: 1, get_socket_ip: 1, get_socket_port_connected: 1]

  alias ElixIRCd.Command.Lusers
  alias ElixIRCd.Command.Mode
  alias ElixIRCd.Command.Motd
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils

  @doc """
  Handles the user handshake.

  This should be called around a transaction.
  The `user` should be loaded in the same transaction.
  """
  @spec handle(User.t()) :: :ok
  def handle(user) when user.nick != nil and user.ident != nil and user.realname != nil do
    with :ok <- check_server_password(user),
         {:ok, {userid, hostname}} <- handle_async_data(user) do
      updated_user =
        Users.update(user, %{
          ident: userid || user.ident,
          hostname: hostname,
          registered: true,
          registered_at: DateTime.utc_now()
        })

      send_welcome(updated_user)
      Lusers.send_lusers(updated_user)
      # Feature: implements RPL_ISUPPORT - https://modern.ircdocs.horse/#feature-advertisement
      # See: lib/elixircd/command/version.ex
      Motd.send_motd(updated_user)
      send_user_modes(updated_user)
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

  @spec handle_async_data(User.t()) :: {:ok, {String.t() | nil, String.t()}} | {:error, String.t()}
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

    Utils.query_identd_userid(ip, port_connected)
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

  @spec send_welcome(User.t()) :: :ok
  defp send_welcome(user) do
    server_name = Application.get_env(:elixircd, :server)[:name]
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]
    app_version = "ElixIRCd-#{Application.spec(:elixircd, :vsn)}"
    server_start_date = :persistent_term.get(:server_start_time) |> Calendar.strftime("%Y-%m-%d")
    usermodes = Mode.UserModes.modes() |> Enum.join("")
    channelmodes = Mode.ChannelModes.modes() |> Enum.join("")

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
        trailing: "Your host is #{server_name}, running version #{app_version}."
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_created,
        params: [user.nick],
        trailing: "This server was created #{server_start_date}"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_myinfo,
        params: [user.nick],
        trailing: "#{server_hostname} #{app_version} #{usermodes} #{channelmodes}"
      })
    ]
    |> Messaging.broadcast(user)
  end

  @spec send_user_modes(User.t()) :: :ok
  defp send_user_modes(%User{nick: nick, modes: modes} = user) when modes != [] do
    Message.build(%{prefix: nick, command: "MODE", params: [nick], trailing: Mode.UserModes.display_modes(modes)})
    |> Messaging.broadcast(user)
  end

  defp send_user_modes(_user), do: :ok
end
