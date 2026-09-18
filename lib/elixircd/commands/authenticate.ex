defmodule ElixIRCd.Commands.Authenticate do
  @moduledoc """
  This module defines the AUTHENTICATE command.

  AUTHENTICATE implements SASL authentication during the connection handshake.
  It allows users to authenticate before completing registration (NICK + USER).

  AUTHENTICATE is only valid during CAP negotiation (between `CAP LS` and `CAP END`).

  Supported mechanisms:
  - PLAIN: Simple username/password authentication
  - ECDSA-NIST256P-CHALLENGE: Account public-key challenge authentication

  The authentication flow:
  1. Client: AUTHENTICATE PLAIN
  2. Server: AUTHENTICATE +
  3. Client: AUTHENTICATE <base64-encoded-credentials>
  4. Server: 903 (success) or 904 (failure)
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [notify_account_change: 2, sync_registered_mode: 1]
  import ElixIRCd.Utils.Protocol, only: [user_reply: 1, user_mask: 1, user_mask: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Ecdsa

  @ecdsa_mechanism "ECDSA-NIST256P-CHALLENGE"
  @ecdsa_challenge_bytes 32
  @max_authenticate_length 400
  @max_sasl_length 16_384

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
      "sasl" not in user.capabilities ->
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
        %Message{
          command: :err_saslalready,
          params: [nick_or_asterisk(user)],
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
      case SaslSessions.get(user.pid) do
        {:ok, session} -> handle_auth_data(user, data, session)
        {:error, :sasl_session_not_found} -> handle_no_session(user)
      end
    else
      handle_mechanism_selection(user, data)
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

  @spec handle_mechanism_selection(User.t(), String.t()) :: :ok
  defp handle_mechanism_selection(user, mechanism) do
    normalized_mechanism = String.upcase(mechanism)
    sasl_config = Application.fetch_env!(:elixircd, :sasl)
    max_attempts = Keyword.fetch!(sasl_config, :max_attempts_per_connection)
    current_attempts = user.sasl_attempts || 0
    supported_mechanisms = supported_mechanisms()

    cond do
      current_attempts >= max_attempts ->
        %Message{
          command: :err_saslfail,
          params: [nick_or_asterisk(user)],
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

      normalized_mechanism not in supported_mechanisms ->
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
    sasl_config = Application.fetch_env!(:elixircd, :sasl)
    Keyword.get(sasl_config[:plain] || [], :enabled, false)
  end

  defp mechanism_enabled?(@ecdsa_mechanism) do
    sasl_config = Application.fetch_env!(:elixircd, :sasl)
    Keyword.get(sasl_config[:ecdsa] || [], :enabled, false)
  end

  @spec supported_mechanisms() :: [String.t()]
  defp supported_mechanisms do
    sasl_config = Application.fetch_env!(:elixircd, :sasl)

    mechanisms = ["PLAIN"]

    if Keyword.has_key?(sasl_config, :ecdsa), do: mechanisms ++ [@ecdsa_mechanism], else: mechanisms
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

  @spec handle_auth_data(User.t(), String.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp handle_auth_data(user, data, _session) when byte_size(data) > @max_authenticate_length do
    %Message{
      command: :err_sasltoolong,
      params: [user_reply(user)],
      trailing: "SASL message too long"
    }
    |> Dispatcher.broadcast(:server, user)

    SaslSessions.delete(user.pid)
  end

  defp handle_auth_data(user, data, session) when byte_size(session.buffer) + byte_size(data) > @max_sasl_length do
    %Message{
      command: :err_saslfail,
      params: [user_reply(user)],
      trailing: "SASL authentication failed: Response exceeds server limit"
    }
    |> Dispatcher.broadcast(:server, user)

    SaslSessions.delete(user.pid)
  end

  defp handle_auth_data(user, "+", session) do
    process_sasl_data(user, session)
  end

  defp handle_auth_data(user, data, session) do
    accumulated_buffer = session.buffer <> data

    if byte_size(data) < @max_authenticate_length do
      updated_session = SaslSessions.update(session, %{buffer: accumulated_buffer})
      process_sasl_data(user, updated_session)
    else
      SaslSessions.update(session, %{buffer: accumulated_buffer})

      :ok
    end
  end

  @spec process_sasl_data(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp process_sasl_data(user, %{mechanism: "PLAIN"} = session) do
    process_plain_auth(user, session)
  end

  defp process_sasl_data(user, %{mechanism: @ecdsa_mechanism, state: nil} = session) do
    start_ecdsa_challenge(user, session)
  end

  defp process_sasl_data(user, %{mechanism: @ecdsa_mechanism, state: state} = session)
       when is_map(state) do
    verify_ecdsa_response(user, session, state)
  end

  defp process_sasl_data(user, _session) do
    handle_unsupported_mechanism(user)
  end

  @spec start_ecdsa_challenge(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp start_ecdsa_challenge(user, session) do
    with {:ok, account_name} <- decode_ecdsa_account(session.buffer),
         {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(account_name),
         {:ok, account_nick} <- RegisteredNicks.get_by_nickname(registered_nick.account_name),
         {:ok, public_key} <- decode_ecdsa_public_key(Map.get(account_nick.settings, :pubkey)) do
      challenge = :crypto.strong_rand_bytes(@ecdsa_challenge_bytes)

      SaslSessions.update(session, %{
        buffer: "",
        state: %{account: account_nick.account_name, challenge: challenge, public_key: public_key}
      })

      %Message{command: "AUTHENTICATE", params: [Base.encode64(challenge)]}
      |> Dispatcher.broadcast(:server, user)
    else
      _ -> fail_ecdsa_authentication(user)
    end
  end

  @spec verify_ecdsa_response(User.t(), ElixIRCd.Tables.SaslSession.t(), map()) :: :ok
  defp verify_ecdsa_response(user, session, %{account: account_name, challenge: challenge, public_key: public_key}) do
    with {:ok, signature} <- Base.decode64(session.buffer),
         true <- valid_ecdsa_signature?(challenge, signature, public_key),
         {:ok, account_nick} <- RegisteredNicks.get_by_nickname(account_name) do
      complete_sasl_authentication(user, account_nick)
    else
      _ -> fail_ecdsa_authentication(user)
    end
  end

  @spec decode_ecdsa_account(String.t()) :: {:ok, String.t()} | :error
  defp decode_ecdsa_account(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         true <- String.valid?(decoded),
         [authcid | authzid_parts] <- :binary.split(decoded, <<0>>, [:global]),
         true <- valid_ecdsa_account_part?(authcid),
         true <- valid_ecdsa_authzid?(authcid, authzid_parts) do
      {:ok, authcid}
    else
      _ -> :error
    end
  end

  @spec valid_ecdsa_account_part?(String.t()) :: boolean()
  defp valid_ecdsa_account_part?(account_name) do
    account_name != "" and byte_size(account_name) <= 64 and
      not Regex.match?(~r/[\x00-\x1f\x7f]/, account_name)
  end

  @spec valid_ecdsa_authzid?(String.t(), [String.t()]) :: boolean()
  defp valid_ecdsa_authzid?(_authcid, []), do: true
  defp valid_ecdsa_authzid?(_authcid, [""]), do: true

  defp valid_ecdsa_authzid?(authcid, [authzid]) do
    valid_ecdsa_account_part?(authzid) and CaseMapping.normalize(authcid) == CaseMapping.normalize(authzid)
  end

  defp valid_ecdsa_authzid?(_authcid, _authzid_parts), do: false

  @spec decode_ecdsa_public_key(String.t() | nil) :: {:ok, binary()} | :error
  defp decode_ecdsa_public_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded, padding: false) do
      {:ok, <<prefix, _x::binary-size(32)>> = public_key} when prefix in [2, 3] ->
        if Ecdsa.valid_compressed_p256_public_key?(public_key), do: {:ok, public_key}, else: :error

      _ ->
        :error
    end
  end

  defp decode_ecdsa_public_key(_encoded), do: :error

  @spec valid_ecdsa_signature?(binary(), binary(), binary()) :: boolean()
  defp valid_ecdsa_signature?(challenge, signature, public_key)
       when byte_size(signature) in 8..128 do
    :crypto.verify(:ecdsa, :sha256, challenge, signature, [public_key, :secp256r1])
  end

  defp valid_ecdsa_signature?(_challenge, _signature, _public_key), do: false

  @spec fail_ecdsa_authentication(User.t()) :: :ok
  defp fail_ecdsa_authentication(user) do
    send_sasl_failure(user, "SASL authentication failed")
    SaslSessions.delete(user.pid)
  end

  @spec process_plain_auth(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp process_plain_auth(user, session) do
    sasl_config = Application.fetch_env!(:elixircd, :sasl)
    require_tls = Keyword.fetch!(sasl_config[:plain], :require_tls)

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
    case RegisteredNicks.get_by_nickname(registered_nick.account_name) do
      {:ok, account_nick} ->
        cond do
          Map.get(account_nick.settings, :secure) == true and user.transport not in [:tls, :wss] ->
            send_sasl_failure(user, "SASL authentication requires a secure TLS connection for this account")
            SaslSessions.delete(user.pid)

          Argon2.verify_pass(password, account_nick.password_hash) ->
            complete_sasl_authentication(user, account_nick)

          true ->
            Logger.debug("SASL authentication failed: invalid password for #{registered_nick.nickname}")
            send_sasl_failure(user, "SASL authentication failed")
            SaslSessions.delete(user.pid)
        end

      {:error, :registered_nick_not_found} ->
        %Message{
          command: :err_saslfail,
          params: [user_reply(user)],
          trailing: "SASL authentication failed"
        }
        |> Dispatcher.broadcast(:server, user)

        SaslSessions.delete(user.pid)
    end
  end

  @spec send_sasl_failure(User.t(), String.t()) :: :ok
  defp send_sasl_failure(user, reason) do
    %Message{
      command: :err_saslfail,
      params: [user_reply(user)],
      trailing: reason
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec complete_sasl_authentication(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp complete_sasl_authentication(user, registered_nick) do
    Logger.info("SASL authentication successful for #{registered_nick.nickname} from #{user_mask(user)}")

    RegisteredNicks.update(registered_nick, %{
      last_seen_at: DateTime.utc_now()
    })

    updated_user =
      Users.update(user, %{
        identified_as: registered_nick.account_name,
        sasl_authenticated: true,
        sasl_attempts: 0
      })

    updated_user = sync_registered_mode(updated_user)
    SaslSessions.delete(user.pid)

    account_name = registered_nick.account_name

    mask = user_mask(user, :registration)

    %Message{
      command: :rpl_loggedin,
      params: [
        nick_or_asterisk(user),
        mask,
        account_name
      ],
      trailing: "You are now logged in as #{account_name}"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    %Message{
      command: :rpl_saslsuccess,
      params: [nick_or_asterisk(user)],
      trailing: "SASL authentication successful"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    notify_account_change(updated_user, account_name)
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
    mechanisms = Enum.join(supported_mechanisms(), ",")

    %Message{
      command: :rpl_saslmechs,
      params: [user_reply(user), mechanisms],
      trailing: "are available SASL mechanisms"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec sasl_enabled?() :: boolean()
  defp sasl_enabled? do
    Application.fetch_env!(:elixircd, :capabilities)[:sasl]
  end

  @spec nick_or_asterisk(User.t()) :: String.t()
  defp nick_or_asterisk(%{nick: nil}), do: "*"
  defp nick_or_asterisk(%{nick: nick}), do: nick
end
