defmodule ElixIRCd.Commands.Authenticate do
  @moduledoc """
  This module defines the AUTHENTICATE command.

  AUTHENTICATE implements SASL authentication during the connection handshake.
  It allows users to authenticate before completing registration (NICK + USER).

  AUTHENTICATE is only valid during CAP negotiation (between `CAP LS` and `CAP END`).

  Supported mechanisms:
  - PLAIN: Simple username/password authentication

  The authentication flow:
  1. Client: AUTHENTICATE PLAIN
  2. Server: AUTHENTICATE +
  3. Client: AUTHENTICATE <base64-encoded-credentials>
  4. Server: 903 (success) or 904 (failure)
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1, user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @supported_mechanisms ["PLAIN"]
  @max_authenticate_length 400

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: true} = user, %{command: "AUTHENTICATE"}) do
    %Message{
      command: :err_alreadyregistered,
      params: [user_reply(user)],
      trailing: "You may not reregister"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "AUTHENTICATE", params: []}) do
    %Message{
      command: :err_needmoreparams,
      params: [user_reply(user), "AUTHENTICATE"],
      trailing: "Not enough parameters"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "AUTHENTICATE", params: [mechanism | _]}) do
    cond do
      "SASL" not in user.capabilities ->
        %Message{
          command: :err_unknowncommand,
          params: [user_reply(user), "AUTHENTICATE"],
          trailing: "You must negotiate SASL capability first"
        }
        |> Dispatcher.broadcast(:server, user)

      user.cap_negotiating != true ->
        %Message{
          command: :err_notregistered,
          params: [user_reply(user)],
          trailing: "You have not registered"
        }
        |> Dispatcher.broadcast(:server, user)

      user.identified_as != nil and user.sasl_authenticated == true ->
        nick_reply = if user.nick, do: user.nick, else: "*"

        %Message{
          command: :err_saslalready,
          params: [nick_reply],
          trailing: "You have already authenticated using SASL"
        }
        |> Dispatcher.broadcast(:server, user)

      true ->
        handle_authenticate(user, mechanism)
    end
  end

  @spec handle_authenticate(User.t(), String.t()) :: :ok
  defp handle_authenticate(user, "*") do
    handle_abort(user)
  end

  defp handle_authenticate(user, data) do
    if SaslSessions.exists?(user.pid) do
      handle_auth_data(user, data)
    else
      handle_mechanism_selection(user, data)
    end
  end

  @spec handle_mechanism_selection(User.t(), String.t()) :: :ok
  defp handle_mechanism_selection(user, mechanism) do
    normalized_mechanism = String.upcase(mechanism)
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    max_attempts = Keyword.get(sasl_config, :max_attempts_per_connection, 3)
    current_attempts = user.sasl_attempts || 0
    nick_reply = if user.nick, do: user.nick, else: "*"

    cond do
      current_attempts >= max_attempts ->
        %Message{
          command: :err_saslfail,
          params: [nick_reply],
          trailing: "Too many SASL authentication attempts"
        }
        |> Dispatcher.broadcast(:server, user)

      not sasl_enabled?() ->
        %Message{
          command: :rpl_saslmechs,
          params: [user_reply(user)],
          trailing: ""
        }
        |> Dispatcher.broadcast(:server, user)

        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "SASL authentication is not enabled"
        }
        |> Dispatcher.broadcast(:server, user)

      normalized_mechanism not in @supported_mechanisms ->
        Users.update(user, %{sasl_attempts: current_attempts + 1})
        send_available_mechanisms(user)

        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "SASL mechanism not supported"
        }
        |> Dispatcher.broadcast(:server, user)

      not mechanism_enabled?(normalized_mechanism) ->
        Users.update(user, %{sasl_attempts: current_attempts + 1})
        send_available_mechanisms(user)

        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "SASL mechanism is disabled by server configuration"
        }
        |> Dispatcher.broadcast(:server, user)

      true ->
        Users.update(user, %{sasl_attempts: current_attempts + 1})
        start_sasl_session(user, normalized_mechanism)
    end
  end

  @spec mechanism_enabled?(String.t()) :: boolean()
  defp mechanism_enabled?("PLAIN") do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    Keyword.get(sasl_config[:plain] || [], :enabled, true)
  end

  @spec start_sasl_session(User.t(), String.t()) :: :ok
  defp start_sasl_session(user, mechanism) do
    SaslSessions.create(%{
      user_pid: user.pid,
      mechanism: mechanism,
      buffer: ""
    })

    %Message{command: "AUTHENTICATE", params: ["+"]}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_auth_data(User.t(), String.t()) :: :ok
  defp handle_auth_data(user, data) do
    case SaslSessions.get(user.pid) do
      {:ok, session} -> handle_auth_data_with_session(user, data, session)
      {:error, :sasl_session_not_found} -> handle_no_session(user)
    end
  end

  @spec handle_no_session(User.t()) :: :ok
  defp handle_no_session(user) do
    %Message{
      command: :err_saslfail,
      params: [user_reply(user)],
      trailing: "SASL authentication is not in progress"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_auth_data_with_session(User.t(), String.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp handle_auth_data_with_session(user, data, session) do
    cond do
      String.length(data) > @max_authenticate_length ->
        %Message{
          command: :err_sasltoolong,
          params: [user_reply(user)],
          trailing: "SASL message too long"
        }
        |> Dispatcher.broadcast(:server, user)

        SaslSessions.delete(user.pid)

      data == "+" ->
        process_sasl_data(user, session)

      true ->
        accumulated_buffer = session.buffer <> data

        if String.ends_with?(data, "=") or String.length(data) < @max_authenticate_length do
          updated_session = SaslSessions.update(session, %{buffer: accumulated_buffer})
          process_sasl_data(user, updated_session)
        else
          SaslSessions.update(session, %{buffer: accumulated_buffer})

          %Message{command: "AUTHENTICATE", params: ["+"]}
          |> Dispatcher.broadcast(:server, user)
        end
    end
  end

  @spec process_sasl_data(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp process_sasl_data(user, session) do
    case session.mechanism do
      "PLAIN" -> process_plain_auth(user, session)
      _ -> handle_unsupported_mechanism(user)
    end
  end

  @spec process_plain_auth(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp process_plain_auth(user, session) do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    require_tls = Keyword.get(sasl_config[:plain] || [], :require_tls, true)

    if require_tls and user.transport not in [:tls, :wss] do
      %Message{
        command: :err_saslfail,
        params: [user_reply(user)],
        trailing: "PLAIN mechanism requires TLS connection"
      }
      |> Dispatcher.broadcast(:server, user)

      SaslSessions.delete(user.pid)
    else
      do_process_plain_auth(user, session)
    end
  end

  @spec do_process_plain_auth(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp do_process_plain_auth(user, session) do
    case decode_plain_credentials(session.buffer) do
      {:ok, {authzid, authcid, password}} ->
        username = if authcid != "", do: authcid, else: authzid
        authenticate_user(user, username, password)

      {:error, reason} ->
        Logger.debug("SASL PLAIN decode error from #{user_mask(user)}: #{reason}")

        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "SASL authentication failed: Invalid credentials format"
        }
        |> Dispatcher.broadcast(:server, user)

        SaslSessions.delete(user.pid)
    end
  end

  @spec decode_plain_credentials(String.t()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:error, String.t()}
  defp decode_plain_credentials(base64_data) do
    case Base.decode64(base64_data) do
      {:ok, decoded} ->
        parts = String.split(decoded, "\0", parts: 3)

        case parts do
          [authzid, authcid, password] when authcid != "" and password != "" ->
            {:ok, {authzid, authcid, password}}

          [authzid, authcid, password] when authzid != "" and password != "" ->
            {:ok, {authzid, authcid, password}}

          _ ->
            {:error, "Invalid PLAIN format"}
        end

      :error ->
        {:error, "Invalid base64 encoding"}
    end
  end

  @spec authenticate_user(User.t(), String.t(), String.t()) :: :ok
  defp authenticate_user(user, username, password) do
    Logger.debug("SASL authentication attempt for user #{username} from #{user_mask(user)}")

    case RegisteredNicks.get_by_nickname(username) do
      {:ok, registered_nick} ->
        verify_password(user, registered_nick, password)

      {:error, :registered_nick_not_found} ->
        Logger.debug("SASL authentication failed: user #{username} not found")

        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "SASL authentication failed"
        }
        |> Dispatcher.broadcast(:server, user)

        SaslSessions.delete(user.pid)
    end
  end

  @spec verify_password(User.t(), ElixIRCd.Tables.RegisteredNick.t(), String.t()) :: :ok
  defp verify_password(user, registered_nick, password) do
    if Argon2.verify_pass(password, registered_nick.password_hash) do
      complete_sasl_authentication(user, registered_nick)
    else
      Logger.debug("SASL authentication failed: invalid password for #{registered_nick.nickname}")

      %Message{
        command: :err_saslfail,
        params: [user_reply(user)],
        trailing: "SASL authentication failed"
      }
      |> Dispatcher.broadcast(:server, user)

      SaslSessions.delete(user.pid)
    end
  end

  @spec complete_sasl_authentication(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp complete_sasl_authentication(user, registered_nick) do
    Logger.info("SASL authentication successful for #{registered_nick.nickname} from #{user_mask(user)}")

    RegisteredNicks.update(registered_nick, %{
      last_seen_at: DateTime.utc_now()
    })

    new_modes = Enum.uniq(user.modes ++ ["r"])

    updated_user =
      Users.update(user, %{
        identified_as: registered_nick.nickname,
        sasl_authenticated: true,
        sasl_attempts: 0,
        modes: new_modes
      })

    SaslSessions.delete(user.pid)

    account_name = registered_nick.nickname
    nick_to_use = if user.nick, do: user.nick, else: "*"

    hostname = if user.cloaked_hostname, do: user.cloaked_hostname, else: user.hostname
    ident = String.slice(user.ident, 0..9)
    mask = if user.nick, do: "#{user.nick}!#{ident}@#{hostname}", else: "*"

    %Message{
      command: :rpl_loggedin,
      params: [
        nick_to_use,
        mask,
        account_name
      ],
      trailing: "You are now logged in as #{account_name}"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    %Message{
      command: :rpl_saslsuccess,
      params: [nick_to_use],
      trailing: "SASL authentication successful"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    notify_account_change(updated_user, account_name)
  end

  @spec notify_account_change(User.t(), String.t()) :: :ok
  defp notify_account_change(user, account) do
    account_notify_supported = Application.get_env(:elixircd, :capabilities)[:account_notify] || false

    if account_notify_supported do
      watchers =
        Users.get_in_shared_channels_with_capability(user, "ACCOUNT-NOTIFY", true)
        |> Enum.reject(&(&1.pid == user.pid))

      if watchers != [] do
        %Message{command: "ACCOUNT", params: [account]}
        |> Dispatcher.broadcast(user, watchers)
      end
    end

    :ok
  end

  @spec handle_abort(User.t()) :: :ok
  defp handle_abort(user) do
    if SaslSessions.exists?(user.pid) do
      Logger.debug("SASL authentication aborted by client #{user_mask(user)}")

      %Message{
        command: :err_saslaborted,
        params: [user_reply(user)],
        trailing: "SASL authentication aborted"
      }
      |> Dispatcher.broadcast(:server, user)

      SaslSessions.delete(user.pid)
    else
      %Message{
        command: :err_saslfail,
        params: [user_reply(user)],
        trailing: "SASL authentication is not in progress"
      }
      |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec handle_unsupported_mechanism(User.t()) :: :ok
  defp handle_unsupported_mechanism(user) do
    send_available_mechanisms(user)

    %Message{
      command: :err_saslfail,
      params: [user_reply(user)],
      trailing: "SASL mechanism not supported"
    }
    |> Dispatcher.broadcast(:server, user)

    SaslSessions.delete(user.pid)
  end

  @spec send_available_mechanisms(User.t()) :: :ok
  defp send_available_mechanisms(user) do
    mechanisms = Enum.join(@supported_mechanisms, ",")

    %Message{
      command: :rpl_saslmechs,
      params: [user_reply(user), mechanisms],
      trailing: "are available SASL mechanisms"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec sasl_enabled?() :: boolean()
  defp sasl_enabled? do
    Application.get_env(:elixircd, :capabilities)[:sasl] || false
  end
end
