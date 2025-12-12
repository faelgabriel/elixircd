defmodule ElixIRCd.Commands.Authenticate do
  @moduledoc """
  This module defines the AUTHENTICATE command.

  AUTHENTICATE implements SASL authentication during the connection handshake.
  It allows users to authenticate before completing registration (NICK + USER).

  Supported mechanisms:
  - PLAIN: Simple username/password authentication
  - SCRAM-SHA-256/512: Challenge-response authentication
  - EXTERNAL: Certificate-based authentication
  - OAUTHBEARER: OAuth token-based authentication

  The authentication flow:
  1. Client: AUTHENTICATE <mechanism>
  2. Server: AUTHENTICATE +
  3. Client: AUTHENTICATE <base64-encoded-credentials>
  4. Server: 903 (success) or 904 (failure)
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1, user_mask: 1]

  alias ElixIRCd.Commands.Authenticate.External
  alias ElixIRCd.Commands.Authenticate.Oauthbearer
  alias ElixIRCd.Commands.Authenticate.Scram
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @supported_mechanisms ["PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512", "EXTERNAL", "OAUTHBEARER"]
  @max_authenticate_length 400

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: true} = user, %{command: "AUTHENTICATE"}) do
    # SASL must be done before registration (before NICK+USER handshake completes)
    %Message{
      command: :err_alreadyregistered,
      params: [user_reply(user)],
      trailing: "You may not reregister"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(%{identified_as: identified_as, sasl_authenticated: true} = user, %{command: "AUTHENTICATE"})
      when identified_as != nil do
    # User is already authenticated via SASL (not NickServ)
    %Message{
      command: :err_saslalready,
      params: [user_reply(user)],
      trailing: "You have already authenticated using SASL"
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
    if "SASL" in user.capabilities do
      handle_authenticate(user, mechanism)
    else
      %Message{
        command: :err_unknowncommand,
        params: [user_reply(user), "AUTHENTICATE"],
        trailing: "You must negotiate SASL capability first"
      }
      |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec handle_authenticate(User.t(), String.t()) :: :ok
  defp handle_authenticate(user, "*") do
    # Client is aborting authentication
    handle_abort(user)
  end

  defp handle_authenticate(user, data) do
    if SaslSessions.exists?(user.pid) do
      # Client is sending authentication data
      handle_auth_data(user, data)
    else
      # Client is initiating authentication with a mechanism
      handle_mechanism_selection(user, data)
    end
  end

  @spec handle_mechanism_selection(User.t(), String.t()) :: :ok
  defp handle_mechanism_selection(user, mechanism) do
    normalized_mechanism = String.upcase(mechanism)
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    max_attempts = Keyword.get(sasl_config, :max_attempts_per_connection, 3)
    current_attempts = user.sasl_attempts || 0

    cond do
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

      current_attempts >= max_attempts ->
        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "Too many SASL authentication attempts"
        }
        |> Dispatcher.broadcast(:server, user)

      normalized_mechanism not in @supported_mechanisms ->
        send_available_mechanisms(user)

        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "SASL mechanism not supported"
        }
        |> Dispatcher.broadcast(:server, user)

      not mechanism_enabled?(normalized_mechanism) ->
        send_available_mechanisms(user)

        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "SASL mechanism is disabled by server configuration"
        }
        |> Dispatcher.broadcast(:server, user)

      true ->
        # Increment attempt counter
        Users.update(user, %{sasl_attempts: current_attempts + 1})
        start_sasl_session(user, normalized_mechanism)
    end
  end

  @spec mechanism_enabled?(String.t()) :: boolean()
  defp mechanism_enabled?(mechanism) do
    sasl_config = Application.get_env(:elixircd, :sasl, [])

    case mechanism do
      "PLAIN" -> plain_enabled?(sasl_config)
      "SCRAM-SHA-256" -> scram_sha256_enabled?(sasl_config)
      "SCRAM-SHA-512" -> scram_sha512_enabled?(sasl_config)
      "EXTERNAL" -> external_enabled?(sasl_config)
      "OAUTHBEARER" -> oauthbearer_enabled?(sasl_config)
      _ -> false
    end
  end

  defp plain_enabled?(sasl_config) do
    Keyword.get(sasl_config[:plain] || [], :enabled, true)
  end

  defp scram_sha256_enabled?(sasl_config) do
    scram_config = sasl_config[:scram] || []

    Keyword.get(scram_config, :enabled, true) and
      "SHA-256" in Keyword.get(scram_config, :algorithms, ["SHA-256", "SHA-512"])
  end

  defp scram_sha512_enabled?(sasl_config) do
    scram_config = sasl_config[:scram] || []

    Keyword.get(scram_config, :enabled, true) and
      "SHA-512" in Keyword.get(scram_config, :algorithms, ["SHA-256", "SHA-512"])
  end

  defp external_enabled?(sasl_config) do
    Keyword.get(sasl_config[:external] || [], :enabled, false)
  end

  defp oauthbearer_enabled?(sasl_config) do
    Keyword.get(sasl_config[:oauthbearer] || [], :enabled, false)
  end

  @spec start_sasl_session(User.t(), String.t()) :: :ok
  defp start_sasl_session(user, mechanism) do
    SaslSessions.create(%{
      user_pid: user.pid,
      mechanism: mechanism,
      buffer: ""
    })

    # Request client to send authentication data
    %Message{command: "AUTHENTICATE", params: ["+"]}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_auth_data(User.t(), String.t()) :: :ok
  defp handle_auth_data(user, data) do
    {:ok, session} = SaslSessions.get(user.pid)

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
        # Client is continuing with existing buffer (fragmented message)
        process_sasl_data(user, session)

      true ->
        # Accumulate data in buffer
        accumulated_buffer = (session.buffer || "") <> data

        if String.ends_with?(data, "=") or String.length(data) < @max_authenticate_length do
          # This is the final chunk, process it
          updated_session = SaslSessions.update(session, %{buffer: accumulated_buffer})
          process_sasl_data(user, updated_session)
        else
          # More data expected, send + to continue
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
      "SCRAM-SHA-256" -> process_scram_auth(user, session, :sha256)
      "SCRAM-SHA-512" -> process_scram_auth(user, session, :sha512)
      "EXTERNAL" -> process_external_auth(user, session)
      "OAUTHBEARER" -> process_oauthbearer_auth(user, session)
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
        # authzid is usually empty, authcid is the username
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

  @spec process_scram_auth(User.t(), ElixIRCd.Tables.SaslSession.t(), :sha256 | :sha512) :: :ok
  defp process_scram_auth(user, session, hash_algo) do
    state = session.state || %{}

    # Check if we're waiting for final +
    if state[:scram_step] == 2 do
      if session.buffer == "" or session.buffer == "+" do
        # Final + received, complete authentication
        complete_scram_authentication(user, state[:pending_completion])
      else
        # Unexpected data
        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "Expected empty response after server-final"
        }
        |> Dispatcher.broadcast(:server, user)

        SaslSessions.delete(user.pid)
      end
    else
      # Normal SCRAM processing
      result = Scram.process_step(state, session.buffer, hash_algo)

      case result do
        {:continue, response, new_state} ->
          # Send server response and update state
          SaslSessions.update(session, %{
            state: new_state,
            buffer: ""
          })

          %Message{command: "AUTHENTICATE", params: [response]}
          |> Dispatcher.broadcast(:server, user)

        {:success, response, registered_nick} ->
          # Send server-final-message
          %Message{command: "AUTHENTICATE", params: [response]}
          |> Dispatcher.broadcast(:server, user)

          # Update session to wait for final +
          SaslSessions.update(session, %{
            state: Map.merge(state, %{scram_step: 2, pending_completion: registered_nick}),
            buffer: ""
          })

        {:error, reason} ->
          Logger.debug("SCRAM authentication failed: #{reason}")

          %Message{
            command: :err_saslfail,
            params: [user_reply(user)],
            trailing: "SASL authentication failed"
          }
          |> Dispatcher.broadcast(:server, user)

          SaslSessions.delete(user.pid)
      end
    end
  end

  @spec process_external_auth(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp process_external_auth(user, session) do
    # EXTERNAL.process currently always returns {:error, _}
    # When certificate support is added, this will handle {:ok, account_name}
    case External.process(user, session.buffer) do
      {:error, reason} ->
        Logger.debug("EXTERNAL authentication failed: #{reason}")

        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: reason
        }
        |> Dispatcher.broadcast(:server, user)

        SaslSessions.delete(user.pid)
    end
  end

  @spec process_oauthbearer_auth(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp process_oauthbearer_auth(user, session) do
    case Oauthbearer.process(user, session.buffer) do
      {:ok, identity} ->
        # Map OAuth identity to registered nick
        case RegisteredNicks.get_by_nickname(identity) do
          {:ok, registered_nick} ->
            complete_sasl_authentication(user, registered_nick)

          {:error, _} ->
            send_oauth_error(user, "invalid_token", "Identity not found")
            SaslSessions.delete(user.pid)
        end

      {:error, error_code, error_description} ->
        Logger.debug("OAUTHBEARER authentication failed: #{error_code}")
        send_oauth_error(user, error_code, error_description)
        SaslSessions.delete(user.pid)
    end
  end

  defp send_oauth_error(user, error_code, description) do
    # Send error in JSON format as per RFC 7628
    error_json = Jason.encode!(%{status: "401", schemes: "bearer", scope: "irc", error: error_code})
    error_b64 = Base.encode64(error_json)

    %Message{command: "AUTHENTICATE", params: [error_b64]}
    |> Dispatcher.broadcast(:server, user)

    %Message{
      command: :err_saslfail,
      params: [user_reply(user)],
      trailing: description
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec complete_scram_authentication(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp complete_scram_authentication(user, registered_nick) do
    Logger.info("SCRAM authentication successful for #{registered_nick.nickname} from #{user_mask(user)}")

    # Update registered nick last seen
    RegisteredNicks.update(registered_nick, %{
      last_seen_at: DateTime.utc_now()
    })

    # Add 'r' mode for registered user
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

    # Send 900 RPL_LOGGEDIN
    %Message{
      command: :rpl_loggedin,
      params: [
        user_reply(updated_user),
        user_mask(updated_user),
        account_name
      ],
      trailing: "You are now logged in as #{account_name}"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    # Send 903 RPL_SASLSUCCESS
    %Message{
      command: :rpl_saslsuccess,
      params: [user_reply(updated_user)],
      trailing: "SASL authentication successful"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    # Send ACCOUNT notification
    notify_account_change(updated_user, account_name)
  end

  @spec decode_plain_credentials(String.t()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:error, String.t()}
  defp decode_plain_credentials(base64_data) do
    case Base.decode64(base64_data) do
      {:ok, decoded} ->
        # PLAIN format: authzid \0 authcid \0 password
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
  rescue
    e -> {:error, "Exception decoding credentials: #{inspect(e)}"}
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

    # Update registered nick last seen
    RegisteredNicks.update(registered_nick, %{
      last_seen_at: DateTime.utc_now()
    })

    # Add 'r' mode for registered user
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

    # Send 900 RPL_LOGGEDIN
    %Message{
      command: :rpl_loggedin,
      params: [
        user_reply(updated_user),
        user_mask(updated_user),
        account_name
      ],
      trailing: "You are now logged in as #{account_name}"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    # Send 903 RPL_SASLSUCCESS
    %Message{
      command: :rpl_saslsuccess,
      params: [user_reply(updated_user)],
      trailing: "SASL authentication successful"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    # Send ACCOUNT notification
    notify_account_change(updated_user, account_name)
  end

  @spec notify_account_change(User.t(), String.t()) :: :ok
  defp notify_account_change(user, account) do
    account_notify_supported = Application.get_env(:elixircd, :capabilities)[:account_notify] || false

    if account_notify_supported do
      watchers = Users.get_in_shared_channels_with_capability(user, "ACCOUNT-NOTIFY", true)

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
