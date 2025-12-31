defmodule ElixIRCd.Server.Handshake do
  @moduledoc """
  Module for handling IRC server handshake for users.
  """

  require Logger

  import ElixIRCd.Utils.Network,
    only: [format_ip_address: 1, lookup_hostname: 1, query_identd: 2]

  alias ElixIRCd.Commands.Lusers
  alias ElixIRCd.Commands.Mode
  alias ElixIRCd.Commands.Motd
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Snotice
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Isupport

  @doc """
  Handles the user handshake.

  This should be called around a transaction.
  The `user` should be loaded in the same transaction.
  """
  @spec handle(User.t()) :: :ok
  def handle(user)
      when user.nick != nil and user.ident != nil and user.realname != nil and user.cap_negotiating != true do
    case check_server_password(user) do
      :ok ->
        handle_handshake(user)

      {:error, :bad_password} ->
        %Message{command: :err_passwdmismatch, params: ["*"], trailing: "Bad Password"}
        |> Dispatcher.broadcast(:server, user)

        {:quit, "Bad Password"}
    end
  end

  def handle(_user), do: :ok

  @spec handle_handshake(User.t()) :: :ok
  defp handle_handshake(user) do
    {userid, hostname} = handle_async_data(user)

    new_modes = apply_handshake_modes(user.modes)

    updated_user =
      Users.update(user, %{
        ident: userid || user.ident,
        hostname: hostname,
        modes: new_modes,
        registered: true,
        registered_at: DateTime.utc_now()
      })

    send_welcome(updated_user)
    Lusers.send_lusers(updated_user)
    Isupport.send_isupport_messages(updated_user)
    Motd.send_motd(updated_user)
    send_user_modes(updated_user)
    send_connect_snotice(updated_user)
  end

  @spec send_connect_snotice(User.t()) :: :ok
  defp send_connect_snotice(user) do
    user_info = Snotice.format_user_info(user)
    secure = if "Z" in user.modes, do: " (secure)", else: ""
    Snotice.broadcast(:connect, "Client connecting: #{user_info}#{secure}")
  end

  @spec apply_handshake_modes([String.t()]) :: [String.t()]
  defp apply_handshake_modes(existing_modes) do
    case Application.get_env(:elixircd, :cloaking)[:cloak_on_connect] do
      true -> Enum.uniq(existing_modes ++ ["x"])
      _ -> existing_modes
    end
  end

  @spec check_server_password(User.t()) :: :ok | {:error, :bad_password}
  defp check_server_password(%User{password: password}) do
    case Application.get_env(:elixircd, :server)[:password] do
      nil -> :ok
      ^password -> :ok
      _other -> {:error, :bad_password}
    end
  end

  @spec handle_async_data(User.t()) :: {String.t() | nil, String.t()}
  defp handle_async_data(user) do
    ident_task = Task.async(fn -> check_ident(user) end)
    hostname_task = Task.async(fn -> resolve_hostname(user) end)
    userid = Task.await(ident_task, 10_200)
    hostname = Task.await(hostname_task)

    {userid, hostname}
  end

  @spec check_ident(User.t()) :: String.t() | nil
  defp check_ident(user) do
    case Application.get_env(:elixircd, :ident_service)[:enabled] do
      true -> request_ident(user)
      _ -> nil
    end
  end

  @spec request_ident(user :: User.t()) :: String.t() | nil
  defp request_ident(user) do
    %Message{command: "NOTICE", params: ["*"], trailing: "*** Checking Ident"}
    |> Dispatcher.broadcast(:server, user)

    query_identd(user.ip_address, user.port_connected)
    |> case do
      {:ok, user_id} ->
        %Message{command: "NOTICE", params: ["*"], trailing: "*** Got Ident response"}
        |> Dispatcher.broadcast(:server, user)

        user_id

      {:error, _reason} ->
        %Message{command: "NOTICE", params: ["*"], trailing: "*** No Ident response"}
        |> Dispatcher.broadcast(:server, user)

        nil
    end
  end

  @spec resolve_hostname(user :: User.t()) :: String.t()
  defp resolve_hostname(user) do
    %Message{command: "NOTICE", params: ["*"], trailing: "*** Looking up your hostname..."}
    |> Dispatcher.broadcast(:server, user)

    formatted_ip_address = format_ip_address(user.ip_address)

    case lookup_hostname(user.ip_address) do
      {:ok, hostname} ->
        Logger.debug("Resolved hostname for #{formatted_ip_address}: #{hostname}")

        %Message{command: "NOTICE", params: ["*"], trailing: "*** Found your hostname"}
        |> Dispatcher.broadcast(:server, user)

        hostname

      _error ->
        Logger.debug("Could not resolve hostname for #{formatted_ip_address}")

        %Message{command: "NOTICE", params: ["*"], trailing: "*** Couldn't look up your hostname"}
        |> Dispatcher.broadcast(:server, user)

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
      %Message{
        command: :rpl_welcome,
        params: [user.nick],
        trailing: "Welcome to the #{server_name} Internet Relay Chat Network #{user.nick}"
      },
      %Message{
        command: :rpl_yourhost,
        params: [user.nick],
        trailing: "Your host is #{server_name}, running version #{app_version}."
      },
      %Message{command: :rpl_created, params: [user.nick], trailing: "This server was created #{server_start_date}"},
      %Message{
        command: :rpl_myinfo,
        params: [user.nick],
        trailing: "#{server_hostname} #{app_version} #{usermodes} #{channelmodes}"
      }
    ]
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_user_modes(User.t()) :: :ok
  defp send_user_modes(%User{nick: nick, modes: modes} = user) when modes != [] do
    mode_display = Mode.UserModes.display_modes(user, modes)

    %Message{command: "MODE", params: [nick], trailing: mode_display}
    |> Dispatcher.broadcast(user, user)
  end

  defp send_user_modes(_user), do: :ok
end
