defmodule ElixIRCd.Server.S2S.ServiceEndpoint do
  @moduledoc """
  Authority-local adapter for the logical NickServ and ChanServ endpoints.

  Read-only service commands reuse the existing service grammar and renderers.
  The caller is a UID projection with no PID, and replies are collected as
  structured ENP items after the transaction commits. Mutating service verbs
  remain owner/action operations until their domain extraction is complete.
  """

  alias ElixIRCd.Message
  alias ElixIRCd.Accounts.Password
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelListTombstones
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.PolicyStore
  alias ElixIRCd.Server.S2S.Publication
  alias ElixIRCd.Server.S2S.Requests
  alias ElixIRCd.Server.S2S.Schema
  alias ElixIRCd.Service
  alias ElixIRCd.Services.Nickserv.Register, as: NickservRegister
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Chanserv.Flags, as: ChannelFlags
  alias ElixIRCd.Utils.Chanserv.ModeLock
  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.Utils.Nickserv

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, normalize_mask: 1, user_mask: 1]

  @nickserv_commands ~w(ALIST ACCESS DROP GROUP HELP IDENTIFY INFO LIST LISTCHANS LOGOUT MEMO RECOVER REGAIN REGISTER RELEASE SET STATUS UNGROUP VERIFY GHOST)
  @chanserv_commands ~w(ACCESS ALIST BAN CLEAR DEOP DROP FLAGS HELP INFO INVITE KICK OP REGISTER SET STATUS SYNC TOPIC TRANSFER UNBAN VOICE DEVOICE)
  @status_commands ~w(OP DEOP VOICE DEVOICE)
  @recovery_commands ~w(GHOST RECOVER REGAIN RELEASE)
  @service_names ~w(NickServ ChanServ)
  @messages_key {__MODULE__, :messages}

  @doc "Executes one authority-local read-only logical service request."
  @spec execute(map(), map(), map()) :: {:ok, map() | {:stream, [map()]}} | {:error, String.t(), String.t()}
  def execute(
        %{
          "actor" => %{"user" => uid},
          "args" => %{
            "service" => service,
            "arguments" => arguments,
            "scope" => scope,
            "channel" => channel
          }
        },
        runtime,
        context
      )
      when service in @service_names and is_list(arguments) and scope in ~w(global channel) do
    with :ok <- authority_available?(runtime, context),
         {:ok, verb} <- service_verb(service, arguments),
         :ok <- binary_arguments(arguments),
         :ok <- service_scope(service, verb, arguments, scope, channel),
         {:ok, user} <- caller_user(runtime, uid),
         {:ok, result} <- execute_service_request(context, service, verb, arguments, user, runtime) do
      case result do
        {:async, job_fun} ->
          {:async, job_fun}

        {:async_deferred, job_fun} ->
          {:async_deferred, job_fun}

        {:committed_rows, payload, rows} when is_list(rows) ->
          if rows == [], do: {:ok, payload}, else: {:ok, payload, rows}
      end
    else
      {:error, status, message} -> {:error, status, message}
      {:error, reason} -> {:error, "REJECTED", safe_message(reason)}
    end
  end

  def execute(_frame, _runtime, _context), do: {:error, "UNSUPPORTED", "service operation is not enabled"}

  defp execute_service_request(%{defer_expensive?: true}, "NickServ", "IDENTIFY", arguments, user, runtime) do
    {:ok, {:async_deferred, fn -> deferred_identify_job(arguments, user, runtime) end}}
  end

  defp execute_service_request(%{defer_expensive?: true}, "NickServ", verb, arguments, user, runtime)
       when verb in @recovery_commands do
    {:ok, {:async_deferred, fn -> deferred_recovery_job(verb, arguments, user, runtime) end}}
  end

  defp execute_service_request(%{defer_expensive?: true}, "NickServ", "REGISTER", arguments, user, runtime) do
    {:ok, {:async_deferred, fn -> deferred_nickserv_register(arguments, user, runtime) end}}
  end

  defp execute_service_request(%{defer_expensive?: true}, "NickServ", verb, arguments, user, runtime)
       when verb in ["DROP", "GROUP"] do
    {:ok, {:async_deferred, fn -> deferred_service_dispatch("NickServ", arguments, user, runtime) end}}
  end

  defp execute_service_request(%{defer_expensive?: true}, "ChanServ", "REGISTER", arguments, user, runtime) do
    {:ok, {:async_deferred, fn -> deferred_chanserv_register(arguments, user, runtime) end}}
  end

  defp execute_service_request(_context, service, verb, arguments, user, runtime),
    do: execute_service(service, verb, arguments, user, runtime)

  defp deferred_chanserv_register(arguments, user, runtime) do
    case prepare_chanserv_register(arguments) do
      {:ok, password_hash} ->
        {:deferred_transaction,
         fn ->
           case transactional_state_rows(runtime, fn ->
                  chanserv_register_job(arguments, user, runtime, password_hash)
                end) do
             {:ok, {:committed_rows, payload, rows}} -> {:state_rows, payload, rows}
             {:ok, {:owner_action, action}} -> {:owner_action, action}
             {:error, _status, _message} = error -> error
             _ -> {:error, "REJECTED", "channel registration failed"}
           end
         end}

      {:error, _status, _message} = error ->
        error
    end
  end

  defp deferred_nickserv_register(arguments, user, runtime) do
    case NickservRegister.prepare_registration(user, arguments) do
      {:ok, password} ->
        email = Enum.at(arguments, 2)
        password_hash = Argon2.hash_pwd_salt(password)
        scram_sha_256 = ElixIRCd.Sasl.ScramSha256.configured_credentials(password)

        {:deferred_transaction,
         fn ->
           case dispatch_messages("NickServ", runtime, true, fn ->
                  NickservRegister.handle_prepared(user, email, password_hash, scram_sha_256)
                end) do
             {:ok, items, rows} -> {:state_rows, stream_payload(items), rows}
             {:error, _status, _message} = error -> error
             _ -> {:error, "REJECTED", "nickname registration failed"}
           end
         end}

      {:error, _reason} ->
        {:deferred_transaction,
         fn ->
           case dispatch("NickServ", arguments, user, runtime) do
             {:ok, items, rows} -> {:state_rows, stream_payload(items), rows}
             {:error, _status, _message} = error -> error
             _ -> {:error, "REJECTED", "nickname registration failed"}
           end
         end}
    end
  end

  defp deferred_service_dispatch(service, arguments, user, runtime) do
    {:deferred_transaction,
     fn ->
       case dispatch(service, arguments, user, runtime) do
         {:ok, items, rows} -> {:state_rows, stream_payload(items), rows}
         {:error, _status, _message} = error -> error
         _ -> {:error, "REJECTED", "service command failed"}
       end
     end}
  end

  @doc "Applies the committed authority-side NickServ reservation follow-up."
  @spec apply_follow_up(map(), map()) :: {:ok, [map()]} | {:error, String.t(), String.t()}
  def apply_follow_up(%{"kind" => "reserve_nick", "nickname" => nickname, "expires_at_ms" => expires_at_ms}, runtime)
      when is_binary(nickname) and is_integer(expires_at_ms) do
    with :ok <- valid_reservation_deadline(expires_at_ms),
         {:ok, rows} <- transactional_policy_change(runtime, fn -> reserve_nickname(nickname, expires_at_ms) end) do
      {:ok, rows}
    else
      {:error, status, message} -> {:error, status, message}
      {:error, reason} -> {:error, "REJECTED", safe_message(reason)}
    end
  rescue
    _ -> {:error, "UNKNOWN_OUTCOME", "nickname reservation outcome is unavailable"}
  end

  def apply_follow_up(
        %{
          "kind" => "clear_nick_reservation",
          "nickname" => nickname,
          "expected_expires_at_ms" => expected_expires_at_ms
        },
        runtime
      )
      when is_binary(nickname) and is_integer(expected_expires_at_ms) do
    with {:ok, rows} <-
           transactional_policy_change(runtime, fn ->
             clear_reservation(nickname, expected_expires_at_ms)
           end) do
      {:ok, rows}
    else
      {:error, status, message} -> {:error, status, message}
      {:error, reason} -> {:error, "REJECTED", safe_message(reason)}
    end
  rescue
    _ -> {:error, "UNKNOWN_OUTCOME", "nickname release outcome is unavailable"}
  end

  def apply_follow_up(_follow_up, _runtime),
    do: {:error, "REJECTED", "invalid service follow-up"}

  defp authority_available?(runtime, context) do
    cond do
      context[:local_sid] != context[:services_authority] -> {:error, "UNAVAILABLE", "services authority is elsewhere"}
      not Policy.grant_ready?(runtime.policy) -> {:error, "UNAVAILABLE", "service policy is not ready"}
      true -> :ok
    end
  end

  defp service_verb(service, [verb | _]) when is_binary(verb) do
    normalized = String.upcase(verb)
    allowed = if service == "NickServ", do: @nickserv_commands, else: @chanserv_commands

    if normalized in allowed,
      do: {:ok, normalized},
      else: {:error, "UNSUPPORTED", "service command is not enabled"}
  end

  defp service_verb(_service, _arguments), do: {:error, "REJECTED", "service command is missing"}

  defp binary_arguments(arguments) do
    if Enum.all?(arguments, &is_binary/1), do: :ok, else: {:error, "REJECTED", "service arguments must be text"}
  end

  defp service_scope(service, _verb, arguments, "global", nil),
    do: global_channel_scope(service, arguments)

  defp service_scope("ChanServ", verb, [_, channel_name | _], "channel", channel) do
    if verb in @status_commands and
         String.starts_with?(channel, "#") and
         CaseMapping.normalize(channel_name) == CaseMapping.normalize(channel),
       do: :ok,
       else: {:error, "UNSUPPORTED", "invalid channel service scope"}
  end

  defp service_scope(_service, _verb, _arguments, _scope, _channel),
    do: {:error, "UNSUPPORTED", "invalid channel service scope"}

  defp global_channel_scope("ChanServ", arguments) do
    if Enum.any?(arguments, &(is_binary(&1) and String.starts_with?(&1, "&"))) do
      {:error, "UNSUPPORTED", "local channel services are handled by their home daemon"}
    else
      :ok
    end
  end

  defp global_channel_scope(_service, _arguments), do: :ok

  @doc "Builds the caller context used by authority-local read-only handlers."
  @spec caller_user(map(), String.t()) :: {:ok, User.t()} | {:error, String.t(), String.t()}
  def caller_user(runtime, uid) do
    case runtime.users[uid] do
      %{} = projection -> {:ok, user_from_projection(projection, runtime)}
      _ -> {:error, "NOT_FOUND", "service caller is not reachable"}
    end
  end

  @doc "Builds a read-only C2S-shaped user from a validated network projection."
  @spec user_from_projection(map(), map()) :: User.t()
  def user_from_projection(projection, runtime) do
    home = projection["home"]
    nick = projection["effective_nick"] || projection["requested_nick"]
    secure? = projection["secure_client"] == true
    account_name = account_name(runtime, projection["binding"])
    modes = Enum.map(projection["modes"] || [], &mode_atom/1) |> Enum.reject(&is_nil/1)
    modes = if is_map(projection["binding"]), do: Enum.uniq([:r | modes]), else: modes

    User.new(%{
      uid: projection["uid"],
      pid: nil,
      home_sid: home["sid"],
      home_boot: home["boot"],
      owner_rev: projection["rev"],
      effective_nick: nick,
      nick: nick,
      transport: if(secure?, do: :tls, else: :tcp),
      ip_address: parse_address(projection["address"]),
      port_connected: 0,
      hostname: projection["realhost"],
      cloaked_hostname: projection["displayhost"],
      ident: projection["ident"],
      realname: projection["realname"],
      registered: true,
      modes: modes,
      capabilities: [],
      identified_as: account_name,
      sasl_authenticated: false,
      away_message: away_message(projection["away"]),
      last_activity: div(projection["signon_ms"], 1_000),
      registered_at: DateTime.from_unix!(projection["signon_ms"], :millisecond),
      created_at: DateTime.from_unix!(projection["signon_ms"], :millisecond)
    })
  end

  defp account_name(_runtime, nil), do: nil

  defp account_name(runtime, %{"account_id" => account_id}) do
    case Policy.get(runtime.policy, "account", account_id) do
      {:ok, %{"canonical_name" => name}} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp account_name(_runtime, _binding), do: nil

  defp away_message(%{"text" => text}) when is_binary(text), do: text
  defp away_message(_away), do: nil

  defp mode_atom("o"), do: :o
  defp mode_atom("B"), do: :B
  defp mode_atom("g"), do: :g
  defp mode_atom("H"), do: :H
  defp mode_atom("a"), do: :a
  defp mode_atom("i"), do: :i
  defp mode_atom("w"), do: :w
  defp mode_atom("R"), do: :R
  defp mode_atom("s"), do: :s
  defp mode_atom("x"), do: :x
  defp mode_atom("r"), do: :r
  defp mode_atom(_mode), do: nil

  defp parse_address(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} -> parsed
      _ -> {0, 0, 0, 0}
    end
  end

  defp parse_address(_address), do: {0, 0, 0, 0}

  defp execute_service("NickServ", "IDENTIFY", arguments, user, runtime),
    do: {:ok, {:async, fn -> identify_job(arguments, user, runtime) end}}

  defp execute_service("NickServ", "LOGOUT", _arguments, user, runtime),
    do: {:ok, {:async, fn -> logout_job(user, runtime) end}}

  defp execute_service("NickServ", "VERIFY", arguments, user, runtime),
    do: {:ok, {:async, fn -> verify_job(arguments, user, runtime) end}}

  defp execute_service("NickServ", "UNGROUP", arguments, user, runtime),
    do: {:ok, {:async, fn -> ungroup_job(arguments, user, runtime) end}}

  defp execute_service("NickServ", "INFO", arguments, user, runtime) do
    case dispatch_remote_read("NickServ", fn ->
           ElixIRCd.Services.Nickserv.Info.handle_with_online_lookup(
             user,
             arguments,
             &runtime_online_user(runtime, &1)
           )
         end) do
      {:ok, payload} -> {:ok, {:committed_rows, payload, []}}
      {:error, _status, _message} = error -> error
    end
  end

  defp execute_service("NickServ", "STATUS", arguments, user, runtime) do
    case dispatch_remote_read("NickServ", fn ->
           ElixIRCd.Services.Nickserv.Status.handle_with_online_lookup(
             user,
             arguments,
             &runtime_online_user(runtime, &1)
           )
         end) do
      {:ok, payload} -> {:ok, {:committed_rows, payload, []}}
      {:error, _status, _message} = error -> error
    end
  end

  defp execute_service("NickServ", verb, arguments, user, runtime) when verb in @recovery_commands,
    do: {:ok, {:async, fn -> recovery_job(verb, arguments, user, runtime) end}}

  defp execute_service("ChanServ", "KICK", arguments, user, runtime),
    do: {:ok, {:async, fn -> chanserv_kick_job(arguments, user, runtime) end}}

  defp execute_service("ChanServ", "INVITE", arguments, user, runtime),
    do: {:ok, {:async, fn -> chanserv_invite_job(arguments, user, runtime) end}}

  defp execute_service("ChanServ", "TOPIC", arguments, user, runtime) do
    transactional_state_rows(runtime, fn -> chanserv_topic_job(arguments, user, runtime) end)
  end

  defp execute_service("ChanServ", "SYNC", arguments, user, runtime) do
    transactional_state_rows(runtime, fn -> chanserv_sync_job(arguments, user, runtime) end)
  end

  defp execute_service("ChanServ", "CLEAR", arguments, user, runtime) do
    case transactional_state_rows(runtime, fn -> chanserv_clear_job(arguments, user, runtime) end) do
      {:ok, {:owner_action, action}} -> {:ok, {:async, fn -> {:owner_action, action} end}}
      result -> result
    end
  end

  defp execute_service("ChanServ", "SET", arguments, user, runtime) do
    case transactional_state_rows(runtime, fn -> chanserv_mlock_job(arguments, user, runtime) end) do
      :delegate ->
        with {:ok, items, rows} <- dispatch("ChanServ", arguments, user, runtime) do
          {:ok, {:committed_rows, stream_payload(items), rows}}
        end

      {:ok, {:committed_rows, payload, rows}} ->
        {:ok, {:committed_rows, payload, rows}}

      {:error, _status, _message} = error ->
        error
    end
  end

  defp execute_service("ChanServ", verb, arguments, user, runtime) when verb in ["BAN", "UNBAN"] do
    transactional_state_rows(runtime, fn -> chanserv_list_job(verb, arguments, user, runtime) end)
  end

  defp execute_service("ChanServ", "REGISTER", arguments, user, runtime) do
    case prepare_chanserv_register(arguments) do
      {:ok, password_hash} ->
        transactional_state_rows(runtime, fn -> chanserv_register_job(arguments, user, runtime, password_hash) end)

      {:error, _status, _message} = error ->
        error
    end
  end

  defp execute_service("ChanServ", verb, arguments, user, runtime) when verb in @status_commands do
    transactional_state_rows(runtime, fn -> status_operation(verb, arguments, user, runtime) end)
  end

  defp execute_service(service, _verb, arguments, user, runtime) do
    with {:ok, items, rows} <- dispatch(service, arguments, user, runtime) do
      {:ok, {:committed_rows, stream_payload(items), rows}}
    end
  end

  defp transactional_state_rows(runtime, operation) when is_function(operation, 0) do
    result =
      Memento.transaction!(fn ->
        case operation.() do
          {:ok, payload, rows} when is_map(payload) and is_list(rows) ->
            case policy_change(runtime) do
              {:ok, row} -> {:ok, payload, rows ++ List.wrap(row)}
              {:error, reason} -> Memento.Transaction.abort({:policy_projection_failed, reason})
            end

          {:owner_action, action} when is_map(action) ->
            {:owner_action, action}

          {:error, _status, _message} = error ->
            error

          :delegate ->
            :delegate

          other ->
            Memento.Transaction.abort({:invalid_service_state_result, other})
        end
      end)

    case result do
      {:ok, payload, rows} -> {:ok, {:committed_rows, payload, rows}}
      {:owner_action, action} -> {:ok, {:owner_action, action}}
      :delegate -> :delegate
      {:error, _status, _message} = error -> error
      other -> {:error, "UNKNOWN_OUTCOME", "service state publication is unavailable: #{inspect(other)}"}
    end
  rescue
    _ -> {:error, "UNKNOWN_OUTCOME", "service state publication is unavailable"}
  end

  defp transactional_policy_change(runtime, operation) when is_function(operation, 0) do
    Memento.transaction!(fn ->
      case operation.() do
        :ok ->
          case policy_change(runtime) do
            {:ok, row} -> {:ok, List.wrap(row)}
            {:error, reason} -> Memento.Transaction.abort({:policy_projection_failed, reason})
          end

        {:error, _status, _message} = error ->
          error

        other ->
          Memento.Transaction.abort({:invalid_policy_operation_result, other})
      end
    end)
  rescue
    _ -> {:error, "UNKNOWN_OUTCOME", "service policy publication is unavailable"}
  end

  defp status_operation(verb, arguments, user, runtime) do
    with {:ok, channel_name, target_nick} <- status_arguments(arguments, user),
         {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         {:ok, channel} <- runtime_channel(runtime, channel_name),
         :ok <- status_permission(registered_channel, user, access_entries, verb),
         {:ok, target_uid, target_projection} <- status_target(runtime, target_nick),
         {:ok, membership} <- status_membership(runtime, target_uid, channel_name),
         {:ok, target_user} <- caller_user(runtime, target_uid),
         :ok <- status_secure_check(registered_channel, target_user, verb),
         :ok <- status_peace_check(registered_channel, user, target_user, access_entries, verb),
         {:ok, row, changed} <- status_row(runtime, channel, membership, target_uid, verb) do
      target_name = target_projection["effective_nick"] || target_projection["requested_nick"] || target_nick
      {:ok, status_notice(user, target_name, channel.ref["name"], verb, changed), if(changed, do: [row], else: [])}
    else
      {:error, message} when is_binary(message) ->
        {:ok, status_notice(user, nil, channel_name(arguments), verb, false, message), []}

      {:error, _status, _message} = error ->
        error
    end
  end

  defp status_arguments([_verb, channel_name], user) when is_binary(channel_name) and is_binary(user.nick),
    do: {:ok, channel_name, user.nick}

  defp status_arguments([_verb, channel_name, target_nick], _user)
       when is_binary(channel_name) and is_binary(target_nick),
       do: {:ok, channel_name, target_nick}

  defp status_arguments(_arguments, _user), do: {:error, "Syntax: <command> <channel> [nickname]"}

  defp channel_name([_verb, channel_name | _rest]) when is_binary(channel_name), do: channel_name
  defp channel_name(_arguments), do: "*"

  defp registered_channel_context(channel_name) do
    Memento.transaction!(fn ->
      with {:ok, channel} <- RegisteredChannels.get_by_name(channel_name) do
        entries =
          channel.name
          |> RegisteredChannelAccesses.get_flags_map_by_channel_name()
          |> ChannelFlags.normalize_access_entries()

        {:ok, channel, entries}
      end
    end)
  rescue
    _ -> {:error, "registered channel is unavailable"}
  end

  defp runtime_channel(runtime, channel_name) do
    case runtime.channels[CaseMapping.normalize(channel_name)] do
      %{ref: ref} = channel when is_map(ref) -> {:ok, channel}
      _ -> {:error, "channel is not currently in use"}
    end
  end

  defp status_permission(channel, user, access_entries, verb) do
    permission =
      if verb in ["OP", "DEOP"],
        do: ChannelFlags.can_use_op(channel, user.identified_as, access_entries),
        else: ChannelFlags.can_use_voice(channel, user.identified_as, access_entries)

    case permission do
      :ok -> :ok
      {:error, :access_denied} -> {:error, "access denied"}
    end
  end

  defp status_target(runtime, target_nick) do
    key = CaseMapping.normalize(target_nick)

    case Enum.find(runtime.users, fn {_uid, projection} ->
           CaseMapping.normalize(projection["effective_nick"] || "") == key or
             CaseMapping.normalize(projection["requested_nick"] || "") == key
         end) do
      {uid, projection} -> {:ok, uid, projection}
      nil -> {:error, "nickname is not online"}
    end
  end

  defp status_membership(runtime, uid, channel_name) do
    key = CaseMapping.normalize(channel_name)

    case runtime.memberships[uid] do
      %{entries: entries} = membership ->
        case Enum.find(entries, &(CaseMapping.normalize(&1["channel"]) == key)) do
          nil -> {:error, "nickname is not on channel"}
          entry -> {:ok, %{entry: entry, revision: membership.rev}}
        end

      _ ->
        {:error, "nickname is not on channel"}
    end
  end

  defp status_secure_check(channel, target_user, verb) when verb in ["OP", "VOICE"] do
    if ChannelFlags.secure_grant_allowed?(channel, target_user), do: :ok, else: {:error, "target must be identified"}
  end

  defp status_secure_check(_channel, _target_user, _verb), do: :ok

  defp status_peace_check(channel, user, target_user, access_entries, verb) when verb in ["DEOP", "DEVOICE"] do
    target_account = target_user.identified_as
    caller_account = user.identified_as

    denied =
      Map.get(channel.settings, :peace, false) and is_binary(target_account) and
        is_binary(caller_account) and CaseMapping.normalize(caller_account) != CaseMapping.normalize(target_account) and
        not ChannelFlags.founder?(channel, caller_account) and
        ChannelFlags.access_rank(channel, target_account, access_entries) >=
          ChannelFlags.access_rank(channel, caller_account, access_entries)

    if denied, do: {:error, "peace policy denied the change"}, else: :ok
  end

  defp status_peace_check(_channel, _user, _target_user, _access_entries, _verb), do: :ok

  defp status_row(runtime, channel, membership, uid, verb) do
    mode = if verb in ["OP", "DEOP"], do: "o", else: "v"
    enabled = verb in ["OP", "VOICE"]
    join_id = membership.entry["join_id"]
    current = get_in(channel, [:statuses, {uid, join_id, mode}, :value, :enabled]) == true

    if current == enabled do
      {:ok, nil, false}
    else
      stamp = Output.next_stamp(runtime.sid, runtime.boot)

      row = %{
        "kind" => "member.status",
        "channel" => channel.ref,
        "uid" => uid,
        "join_id" => join_id,
        "mode" => mode,
        "enabled" => enabled,
        "stamp" => stamp,
        "setter" => %{"service" => "ChanServ"}
      }

      if Schema.validate_row(row) == :ok, do: {:ok, row, true}, else: {:error, "invalid status publication"}
    end
  end

  defp status_notice(user, target_name, channel_name, verb, changed, message \\ nil)

  defp status_notice(user, _target_name, channel_name, _verb, _changed, message) when is_binary(message),
    do: service_notice_payload("ChanServ", user, ["#{message} for #{channel_name}."])

  defp status_notice(user, target_name, channel_name, verb, true, nil) do
    action = if verb in ["OP", "VOICE"], do: "granted", else: "removed"
    noun = if verb in ["OP", "DEOP"], do: "operator status", else: "voice status"

    service_notice_payload("ChanServ", user, [
      "#{String.capitalize(noun)} #{action} to #{target_name} on #{channel_name}."
    ])
  end

  defp status_notice(user, target_name, channel_name, verb, false, nil) do
    state = if verb in ["OP", "VOICE"], do: "already has", else: "does not have"
    noun = if verb in ["OP", "DEOP"], do: "operator status", else: "voice status"
    service_notice_payload("ChanServ", user, ["\x02#{target_name}\x02 #{state} #{noun} on #{channel_name}."])
  end

  defp chanserv_topic_job(["TOPIC", channel_name], user, _runtime) when is_binary(channel_name) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         :ok <- ChannelFlags.can_use_topic(registered_channel, user.identified_as, access_entries) do
      message =
        case registered_channel.topic do
          %{text: text} -> "Topic for #{registered_channel.name}: #{text}"
          _ -> "No topic is set for #{registered_channel.name}."
        end

      {:ok, service_notice_payload("ChanServ", user, [message]), []}
    else
      {:error, :registered_channel_not_found} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not registered.")

      {:error, :access_denied} ->
        chanserv_notice_result(user, "Access denied for #{channel_name}.")
    end
  end

  defp chanserv_topic_job(["TOPIC", channel_name | topic_parts], user, runtime)
       when is_binary(channel_name) and is_list(topic_parts) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         :ok <- ChannelFlags.can_use_topic(registered_channel, user.identified_as, access_entries),
         {:ok, topic, set_ms} <- service_topic(topic_parts),
         {:ok, updated} <- update_registered_topic(registered_channel, topic) do
      rows =
        case runtime_channel(runtime, channel_name) do
          {:ok, channel} ->
            [channel_field_row(runtime, channel, "topic", topic_value(topic, set_ms), %{"service" => "ChanServ"})]

          _ ->
            []
        end

      rows = Enum.filter(rows, &is_map/1)

      message =
        if is_nil(topic),
          do: "The topic for #{updated.name} has been cleared.",
          else: "The topic for #{updated.name} has been updated."

      {:ok, service_notice_payload("ChanServ", user, [message]), rows}
    else
      {:error, :registered_channel_not_found} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not registered.")

      {:error, :access_denied} ->
        chanserv_notice_result(user, "Access denied for #{channel_name}.")

      {:error, :topic_too_long} ->
        chanserv_notice_result(user, topic_length_message())

      {:error, status, message} ->
        {:error, status, message}
    end
  end

  defp chanserv_topic_job(_arguments, user, _runtime),
    do: chanserv_notice_result(user, "Syntax: TOPIC <channel> [topic|OFF]")

  defp service_topic(["OFF"]) do
    {:ok, nil, max(Identity.now_ms(), 1)}
  end

  defp service_topic(topic_parts) do
    text = Enum.join(topic_parts, " ")
    max_length = Application.fetch_env!(:elixircd, :channel)[:max_topic_length]

    if String.length(text) <= max_length do
      set_ms = max(Identity.now_ms(), 1)

      {:ok,
       %Channel.Topic{text: text, setter: Service.mask(:chanserv), set_at: DateTime.from_unix!(set_ms, :millisecond)},
       set_ms}
    else
      {:error, :topic_too_long}
    end
  end

  defp topic_length_message do
    max_length = Application.fetch_env!(:elixircd, :channel)[:max_topic_length]
    "Topic too long (maximum length: #{max_length} characters)"
  end

  defp update_registered_topic(registered_channel, topic) do
    {:ok,
     Memento.transaction!(fn ->
       current = Memento.Query.read(RegisteredChannel, registered_channel.name_key, lock: :write)

       RegisteredChannels.update(current || registered_channel, %{
         topic: topic,
         settings: topic_settings(current || registered_channel, topic)
       })
     end)}
  rescue
    _ -> {:error, "UNKNOWN_OUTCOME", "registered topic update is unavailable"}
  end

  defp topic_settings(registered_channel, topic) do
    RegisteredChannel.Settings.update(registered_channel.settings, %{persistent_topic: topic_text(topic)})
  end

  defp topic_value(nil, set_ms), do: %{"text" => "", "setter" => Service.mask(:chanserv), "set_ms" => max(set_ms, 1)}

  defp topic_value(%Channel.Topic{text: text, setter: setter, set_at: set_at}, set_ms),
    do: %{"text" => text, "setter" => setter, "set_ms" => max(DateTime.to_unix(set_at, :millisecond), set_ms)}

  defp chanserv_sync_job(["SYNC", channel_name], user, runtime) when is_binary(channel_name) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         {:ok, channel} <- runtime_channel(runtime, channel_name),
         :ok <- ChannelFlags.can_use_moderation(registered_channel, user.identified_as, access_entries) do
      {status_rows, changed_uids} = sync_status_rows(runtime, channel, registered_channel, access_entries, channel_name)
      mode_rows = sync_mlock_rows(runtime, channel, registered_channel)
      rows = status_rows ++ mode_rows
      count = MapSet.size(changed_uids)

      message =
        if count == 0,
          do: "Channel #{channel.ref["name"]} is already synchronized.",
          else: "Synchronized #{count} #{if(count == 1, do: "user", else: "users")} on #{channel.ref["name"]}."

      {:ok, service_notice_payload("ChanServ", user, [message]), rows}
    else
      {:error, :registered_channel_not_found} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not registered.")

      {:error, "channel is not currently in use"} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not currently in use.")

      {:error, :access_denied} ->
        chanserv_notice_result(user, "Access denied for #{channel_name}.")
    end
  end

  defp chanserv_sync_job(_arguments, user, _runtime),
    do: chanserv_notice_result(user, "Syntax: SYNC <channel>")

  defp sync_status_rows(runtime, channel, registered_channel, access_entries, channel_name) do
    Map.get(runtime, :memberships, %{})
    |> Enum.flat_map(fn {uid, membership} ->
      case Enum.find(membership.entries, &(CaseMapping.normalize(&1["channel"]) == CaseMapping.normalize(channel_name))) do
        nil -> []
        entry -> sync_user_status_rows(runtime, channel, registered_channel, access_entries, uid, membership.rev, entry)
      end
    end)
    |> Enum.reduce({[], MapSet.new()}, fn
      {:row, uid, row}, {rows, users} -> {[row | rows], MapSet.put(users, uid)}
      _unchanged, acc -> acc
    end)
    |> then(fn {rows, users} -> {Enum.reverse(rows), users} end)
  end

  defp sync_user_status_rows(runtime, channel, registered_channel, access_entries, uid, revision, entry) do
    with {:ok, target_user} <- caller_user(runtime, uid) do
      desired = ChannelFlags.desired_channel_modes(registered_channel, target_user.identified_as, access_entries)

      desired =
        if Nickserv.account_setting(target_user.identified_as, :never_op, false),
          do: List.delete(desired, :o),
          else: desired

      membership = %{entry: entry, revision: revision}

      Enum.flat_map([{:o, "OP", "DEOP"}, {:v, "VOICE", "DEVOICE"}], fn {mode, grant, revoke} ->
        current = get_in(channel, [:statuses, {uid, entry["join_id"], Atom.to_string(mode)}, :value, :enabled]) == true
        wanted = mode in desired

        if current == wanted do
          [{:unchanged, uid}]
        else
          verb = if wanted, do: grant, else: revoke

          case status_row(runtime, channel, membership, uid, verb) do
            {:ok, row, true} -> [{:row, uid, row}]
            _ -> [{:unchanged, uid}]
          end
        end
      end)
    else
      _ -> []
    end
  end

  defp sync_mlock_rows(runtime, channel, registered_channel) do
    case Map.get(registered_channel.settings, :mlock) do
      value when is_binary(value) ->
        with {:ok, canonical} <- parse_mlock(value),
             {changes, []} <- ChannelModes.parse_mode_changes(canonical.mode, canonical.values) do
          changes
          |> Enum.flat_map(&mlock_change_row(runtime, channel, &1))
          |> Enum.reject(&is_nil/1)
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp mlock_change_row(runtime, channel, {action, mode}) do
    mode_name = mode_name(mode)
    field = "mode:" <> mode_name
    value = mlock_value(action, mode)
    current = channel_register_value(channel, field, mode)

    if current == value do
      []
    else
      [channel_field_row(runtime, channel, field, value, %{"service" => "ChanServ"})]
    end
  end

  defp mlock_value(:add, {mode, value}), do: {mode, value} |> elem(1)
  defp mlock_value(:add, _mode), do: true
  defp mlock_value(:remove, {_mode, _value}), do: nil
  defp mlock_value(:remove, _mode), do: false

  defp mode_name({mode, _value}), do: Atom.to_string(mode)
  defp mode_name(mode), do: Atom.to_string(mode)

  defp channel_register_value(channel, field, mode) do
    case channel.registers[field] do
      %{value: value} -> value
      _ -> if parameter_mode?(mode), do: nil, else: false
    end
  end

  defp parameter_mode?({mode, _value}), do: parameter_mode?(mode)

  defp parameter_mode?(mode) do
    case Enum.find(ChannelModes.mode_types(), fn {candidate, _type} -> candidate == mode end) do
      {_mode, type} -> type in [:b, :c]
      nil -> false
    end
  end

  defp parse_mlock(value) when is_binary(value) do
    case String.split(value) do
      [mode | values] ->
        with {:ok, canonical} <- ModeLock.validate(mode, values),
             [canonical_mode | canonical_values] <- String.split(canonical) do
          {:ok, %{mode: canonical_mode, values: canonical_values}}
        end

      _ ->
        {:error, :invalid_mode_lock}
    end
  end

  defp channel_field_row(runtime, channel, field, value, setter) do
    stamp = fresh_stamp(runtime, get_in(channel.registers, [field, :stamp]))

    row = %{
      "kind" => "channel.field",
      "channel" => channel.ref,
      "field" => field,
      "value" => value,
      "stamp" => stamp,
      "setter" => setter
    }

    if Schema.validate_row(row) == :ok, do: row, else: nil
  end

  defp fresh_stamp(runtime, [counter, _sid, _boot]) when is_integer(counter),
    do: allocate_after_observing(runtime, counter)

  defp fresh_stamp(runtime, _stamp), do: Output.next_stamp(runtime.sid, runtime.boot)

  defp allocate_after_observing(runtime, counter) do
    :ok = Output.observe_stamp([counter, runtime.sid, runtime.boot])
    Output.next_stamp(runtime.sid, runtime.boot)
  end

  defp chanserv_notice_result(user, message),
    do: {:ok, service_notice_payload("ChanServ", user, [message]), []}

  defp chanserv_clear_job(["CLEAR", channel_name, subcommand | _], user, runtime)
       when is_binary(channel_name) and is_binary(subcommand) do
    case String.upcase(subcommand) do
      "BANS" -> clear_bans_job(channel_name, user, runtime)
      "FLAGS" -> clear_flags_job(channel_name, user)
      "USERS" -> clear_users_job(channel_name, user, runtime)
      unknown -> chanserv_notice_result(user, "Unknown CLEAR subcommand: #{unknown}")
    end
  end

  defp chanserv_clear_job(_arguments, user, _runtime),
    do: chanserv_notice_result(user, "Syntax: CLEAR <channel> {BANS|FLAGS|USERS}")

  defp clear_bans_job(channel_name, user, runtime) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         {:ok, channel} <- runtime_channel(runtime, channel_name),
         :ok <- ChannelFlags.can_use_moderation(registered_channel, user.identified_as, access_entries) do
      entries =
        Memento.transaction!(fn ->
          channel_key = registered_channel.name_key
          bans = ChannelBans.get_by_channel_name_key(channel_key)
          excepts = ChannelExcepts.get_by_channel_name_key(channel_key)
          invexes = ChannelInvexes.get_by_channel_name_key(channel_key)
          records = Enum.map(bans, &{"b", &1}) ++ Enum.map(excepts, &{"e", &1}) ++ Enum.map(invexes, &{"I", &1})
          Enum.each(records, fn {_mode, record} -> delete_channel_list_record(record) end)
          records
        end)

      if entries == [] do
        chanserv_notice_result(user, "There are no ban entries to clear on #{channel.ref["name"]}.")
      else
        set_ms = max(Identity.now_ms(), 1)

        rows =
          Enum.map(entries, fn {mode, record} ->
            channel_list_row(
              channel.ref,
              mode,
              record.mask,
              false,
              record.setter,
              DateTime.from_unix!(set_ms, :millisecond),
              runtime
            )
          end)

        noun = if length(entries) == 1, do: "entry", else: "entries"

        payload =
          service_notice_payload("ChanServ", user, [
            "Cleared #{length(entries)} ban #{noun} from #{channel.ref["name"]}."
          ])

        {:ok, payload, rows}
      end
    else
      {:error, :registered_channel_not_found} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not registered.")

      {:error, "channel is not currently in use"} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not currently in use.")

      {:error, :access_denied} ->
        chanserv_notice_result(user, "Access denied for #{channel_name}.")
    end
  end

  defp delete_channel_list_record(%ElixIRCd.Tables.ChannelBan{} = record), do: ChannelBans.delete(record)
  defp delete_channel_list_record(%ElixIRCd.Tables.ChannelExcept{} = record), do: ChannelExcepts.delete(record)
  defp delete_channel_list_record(%ElixIRCd.Tables.ChannelInvex{} = record), do: ChannelInvexes.delete(record)

  defp clear_flags_job(channel_name, user) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         :ok <- ChannelFlags.can_manage_flags(registered_channel, user.identified_as, access_entries) do
      {clearable, kept} =
        Enum.split_with(access_entries, fn {_account, flags} ->
          ChannelFlags.may_grant?(registered_channel, user.identified_as, flags, "", access_entries)
        end)

      if clearable == [] do
        suffix = if kept == [], do: ".", else: " (#{length(kept)} kept: insufficient access)."

        chanserv_notice_result(
          user,
          "There are no explicit ChanServ flags to clear on #{registered_channel.name}#{suffix}"
        )
      else
        Memento.transaction!(fn ->
          Enum.each(clearable, fn {account_name, _flags} ->
            RegisteredChannelAccesses.delete(registered_channel.name, account_name)
          end)
        end)

        suffix = if kept == [], do: ".", else: " (#{length(kept)} kept: insufficient access)."

        payload =
          service_notice_payload("ChanServ", user, [
            "Cleared #{length(clearable)} ChanServ flag #{if(length(clearable) == 1, do: "entry", else: "entries")} from #{registered_channel.name}#{suffix}"
          ])

        {:ok, payload, []}
      end
    else
      {:error, :registered_channel_not_found} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not registered.")

      {:error, :access_denied} ->
        chanserv_notice_result(user, "Access denied for #{channel_name}.")
    end
  end

  defp clear_users_job(channel_name, user, runtime) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         {:ok, channel} <- runtime_channel(runtime, channel_name),
         :ok <- ChannelFlags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         targets <- clear_user_targets(runtime, channel_name),
         false <- targets == [],
         :ok <- clear_users_peace_check(registered_channel, user, targets, access_entries) do
      reason = "CLEAR USERS used by #{user.nick}"

      actions =
        Enum.map(targets, fn {uid, projection, membership} ->
          owner_action_map(
            runtime,
            projection,
            %{
              "action" => "kick",
              "target_uid" => uid,
              "value" => %{"channel" => channel.ref, "join_id" => membership.entry["join_id"]},
              "reason" => reason
            },
            actor: %{"service" => "ChanServ"}
          )
        end)

      count = length(actions)

      payload =
        service_notice_payload("ChanServ", user, [
          "Cleared #{count} #{if(count == 1, do: "user", else: "users")} from #{channel.ref["name"]}."
        ])

      [first | rest] = actions
      {:owner_action, Map.merge(first, %{success_payload: payload, remaining_actions: rest})}
    else
      {:error, :registered_channel_not_found} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not registered.")

      {:error, "channel is not currently in use"} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not currently in use.")

      {:error, :access_denied} ->
        chanserv_notice_result(user, "Access denied for #{channel_name}.")

      {:error, :peace_denied} ->
        chanserv_notice_result(
          user,
          "Channel #{channel_name} has PEACE enabled; you cannot clear users while a protected target matches."
        )

      true ->
        chanserv_notice_result(user, "There are no users to clear on #{channel_name}.")
    end
  end

  defp clear_user_targets(runtime, channel_name) do
    key = CaseMapping.normalize(channel_name)

    runtime
    |> Map.get(:memberships, %{})
    |> Enum.flat_map(fn {uid, membership} ->
      case Enum.find(Map.get(membership, :entries, []), &(CaseMapping.normalize(&1["channel"]) == key)) do
        nil ->
          []

        entry ->
          case runtime.users[uid] do
            %{} = projection -> [{uid, projection, %{entry: entry, revision: membership.rev}}]
            _ -> []
          end
      end
    end)
    |> Enum.sort_by(fn {uid, _projection, _membership} -> uid end)
  end

  defp clear_users_peace_check(registered_channel, user, targets, access_entries) do
    denied =
      Enum.any?(targets, fn {_uid, projection, _membership} ->
        case caller_user(
               %{
                 users: %{projection["uid"] => projection},
                 policy: %{objects: %{}},
                 sid: "local",
                 boot: projection["home"]["boot"]
               },
               projection["uid"]
             ) do
          {:ok, target_user} ->
            chanserv_peace_check(registered_channel, user, target_user, access_entries) == {:error, :peace_denied}

          _ ->
            true
        end
      end)

    if denied, do: {:error, :peace_denied}, else: :ok
  end

  defp chanserv_mlock_job(["SET", channel_name, "MLOCK"], user, _runtime) when is_binary(channel_name) do
    with {:ok, registered_channel, _entries} <- registered_channel_context(channel_name),
         true <- ChannelFlags.founder?(registered_channel, user.identified_as) do
      message =
        case registered_channel.settings.mlock do
          nil -> "No MLOCK is set for #{registered_channel.name}."
          value -> "MLOCK for #{registered_channel.name} is: #{value}"
        end

      {:ok, service_notice_payload("ChanServ", user, [message]), []}
    else
      {:error, :registered_channel_not_found} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not registered.")

      false ->
        chanserv_notice_result(user, "Access denied. You are not the founder of #{channel_name}.")
    end
  end

  defp chanserv_mlock_job(["SET", channel_name, "MLOCK" | values], user, runtime) when is_binary(channel_name) do
    with {:ok, registered_channel, _entries} <- registered_channel_context(channel_name),
         true <- ChannelFlags.founder?(registered_channel, user.identified_as),
         {:ok, mode_lock} <- parse_mlock_values(values),
         {:ok, updated} <- update_mlock_policy(registered_channel, mode_lock) do
      rows =
        case runtime_channel(runtime, channel_name) do
          {:ok, channel} -> sync_mlock_rows(runtime, channel, updated)
          _ -> []
        end

      message =
        case mode_lock do
          nil -> "MLOCK for #{registered_channel.name} has been unset."
          value -> "MLOCK for #{registered_channel.name} has been set to: #{value}"
        end

      {:ok, service_notice_payload("ChanServ", user, [message]), rows}
    else
      {:error, :registered_channel_not_found} ->
        chanserv_notice_result(user, "Channel #{channel_name} is not registered.")

      false ->
        chanserv_notice_result(user, "Access denied. You are not the founder of #{channel_name}.")

      {:error, reason} ->
        chanserv_notice_result(user, mlock_error_message(reason))
    end
  end

  defp chanserv_mlock_job(_arguments, _user, _runtime), do: :delegate

  defp parse_mlock_values(["OFF"]), do: {:ok, nil}

  defp parse_mlock_values([mode | values]) do
    ModeLock.validate(mode, values)
  end

  defp parse_mlock_values(_values), do: {:error, :empty_mode_lock}

  defp update_mlock_policy(registered_channel, mode_lock) do
    {:ok,
     Memento.transaction!(fn ->
       current = Memento.Query.read(RegisteredChannel, registered_channel.name_key, lock: :write) || registered_channel
       settings = RegisteredChannel.Settings.update(current.settings, %{mlock: mode_lock})
       RegisteredChannels.update(current, %{settings: settings})
     end)}
  rescue
    _ -> {:error, :policy_unavailable}
  end

  defp mlock_error_message(:missing_mode_parameter), do: "MLOCK requires a parameter for every valued mode."
  defp mlock_error_message(:listing_mode), do: "MLOCK does not accept channel list modes."
  defp mlock_error_message(:unsupported_mode), do: "MLOCK does not accept membership or list modes."
  defp mlock_error_message(:invalid_mode_parameter), do: "MLOCK contains an invalid parameter for a channel mode."
  defp mlock_error_message(:empty_mode_lock), do: "Invalid MLOCK. Use channel modes such as +nt or +lk <limit> <key>."
  defp mlock_error_message(_reason), do: "Invalid MLOCK. Use channel modes such as +nt or +lk <limit> <key>."

  defp policy_change(runtime) do
    refreshed =
      Memento.transaction!(fn ->
        Policy.from_sources(
          runtime.policy.epoch,
          RegisteredNicks.get_all(),
          RegisteredChannels.get_all(),
          RegisteredChannelAccesses.get_all(),
          [],
          revision: runtime.policy.revision
        )
      end)

    with {:ok, refreshed} <- refreshed,
         true <- refreshed.objects != runtime.policy.objects do
      changes = policy_changes(runtime.policy.objects, refreshed.objects)
      revision = runtime.policy.revision + 1
      changes = bounded_policy_changes(changes)
      row = %{"kind" => "policy.change", "epoch" => runtime.policy.epoch, "revision" => revision, "changes" => changes}

      case Schema.validate_row(row) do
        :ok ->
          case policy_revision(runtime, revision) do
            {:ok, revision} -> {:ok, %{row | "revision" => revision}}
            {:error, _} = error -> error
          end

        _ ->
          {:error, :invalid_policy_row}
      end
    else
      false -> {:ok, nil}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :policy_projection_failed}
  end

  defp policy_revision(runtime, fallback) do
    case PolicyStore.next_revision(runtime.policy.epoch, runtime.policy.revision) do
      {:ok, revision} -> {:ok, revision}
      {:error, :policy_epoch_mismatch} -> {:ok, fallback}
      {:error, _} = error -> error
    end
  end

  defp bounded_policy_changes(changes) when is_list(changes) do
    encoded = ElixIRCd.Server.S2S.JSON.encode(%{"changes" => changes})

    if length(changes) <= 256 and byte_size(encoded) <= 48 * 1_024, do: changes, else: nil
  end

  defp policy_changes(previous, current) do
    keys = MapSet.union(MapSet.new(Map.keys(previous)), MapSet.new(Map.keys(current)))

    keys
    |> Enum.sort()
    |> Enum.flat_map(fn {entity, key} ->
      case {previous[{entity, key}], current[{entity, key}]} do
        {old, new} when old == new -> []
        {_old, nil} -> [%{"entity" => entity, "key" => key, "value" => nil}]
        {_old, new} -> [%{"entity" => entity, "key" => key, "value" => new}]
      end
    end)
  end

  @doc "Runs the authority-side part of IDENTIFY outside the manager state lock."
  @spec identify_job([String.t()], User.t(), map()) :: term()
  def identify_job(arguments, user, runtime) do
    with {:ok, nickname, password} <- identify_arguments(arguments, user),
         :ok <- identify_precondition(user),
         {:ok, upgraded_account} <- verify_identity(nickname, password, user),
         {:ok, binding} <- account_binding(runtime, upgraded_account),
         {:ok, target_sid} <- target_sid(runtime, user.uid) do
      {:owner_action, identify_owner_action(user, runtime, binding, target_sid)}
    else
      {:error, :already_authenticated} ->
        service_notice(user, "You are already identified. Please /msg NickServ LOGOUT first.")

      {:error, :same_account} ->
        service_notice(user, "You are already identified as your requested account.")

      {:error, :secure_required} ->
        service_notice(user, "This account requires a secure TLS connection for authentication.")

      {:error, :registered_nick_not_found} ->
        service_notice(user, "Authentication failed. Invalid nickname or password.")

      :error ->
        service_notice(user, "Authentication failed. Invalid nickname or password.")

      {:error, "UNAVAILABLE", _message} = error ->
        error

      {:error, status, message} ->
        {:reply, status, Requests.error_payload(status, message)}
    end
  end

  defp deferred_identify_job(arguments, user, runtime) do
    with {:ok, nickname, password} <- identify_arguments(arguments, user),
         :ok <- identify_precondition(user),
         {:ok, verified_account} <- verify_identity_credentials(nickname, password, user),
         {:ok, binding} <- account_binding(runtime, verified_account),
         {:ok, target_sid} <- target_sid(runtime, user.uid) do
      {:deferred_transaction,
       fn ->
         case commit_identity_verification(verified_account, user) do
           {:ok, _updated} ->
             {:owner_action, identify_owner_action(user, runtime, binding, target_sid)}

           {:error, _status, _message} = error ->
             error
         end
       end}
    else
      {:error, :already_authenticated} ->
        service_notice(user, "You are already identified. Please /msg NickServ LOGOUT first.")

      {:error, :same_account} ->
        service_notice(user, "You are already identified as your requested account.")

      {:error, :secure_required} ->
        service_notice(user, "This account requires a secure TLS connection for authentication.")

      {:error, :registered_nick_not_found} ->
        service_notice(user, "Authentication failed. Invalid nickname or password.")

      :error ->
        service_notice(user, "Authentication failed. Invalid nickname or password.")

      {:error, "UNAVAILABLE", _message} = error ->
        error

      {:error, status, message} ->
        {:reply, status, Requests.error_payload(status, message)}
    end
  end

  defp identify_owner_action(user, runtime, binding, target_sid) do
    %{
      target_sid: target_sid,
      actor: %{"service" => "NickServ"},
      method: "user_action",
      args: %{
        "action" => "account",
        "target_uid" => user.uid,
        "value" => %{"binding" => binding, "response_request_id" => nil},
        "reason" => "NickServ IDENTIFY"
      },
      guards: service_guards(user, runtime),
      ttl_ms: 15_000,
      success_payload: Requests.ok_payload(nil)
    }
  end

  @doc "Builds the owner action for remote LOGOUT without touching a remote table."
  @spec logout_job(User.t(), map()) :: term()
  def logout_job(%User{identified_as: nil} = user, _runtime),
    do: service_notice(user, "You are not identified to any nickname.")

  def logout_job(%User{} = user, runtime) do
    with {:ok, target_sid} <- target_sid(runtime, user.uid) do
      {:owner_action,
       %{
         target_sid: target_sid,
         actor: %{"service" => "NickServ"},
         method: "user_action",
         args: %{
           "action" => "account",
           "target_uid" => user.uid,
           "value" => %{"binding" => nil, "response_request_id" => nil},
           "reason" => "NickServ LOGOUT"
         },
         guards: service_guards(user, runtime),
         ttl_ms: 15_000,
         success_payload: Requests.ok_payload(nil)
       }}
    else
      {:error, status, message} -> {:reply, status, Requests.error_payload(status, message)}
    end
  end

  @doc "Runs the authority-side GHOST, RECOVER, REGAIN or RELEASE workflow."
  @spec recovery_job(String.t(), [String.t()], User.t(), map()) :: term()
  def recovery_job(verb, arguments, user, runtime) when verb in @recovery_commands do
    with {:ok, nickname, password} <- recovery_arguments(verb, arguments),
         {:ok, registered_nick} <- authenticate_recovery(nickname, password, user) do
      recovery_operation(verb, registered_nick, user, runtime)
    else
      {:error, :syntax, messages} ->
        service_notice_messages("NickServ", user, messages)

      {:error, :registered_nick_not_found} ->
        service_notice(user, "Nick \x02#{recovery_nickname(arguments)}\x02 is not registered.")

      {:error, :secure_required} ->
        service_notice(user, "This account requires a secure TLS connection for password authentication.")

      {:error, :password_required} ->
        recovery_password_required(verb, user, recovery_nickname(arguments))

      {:error, :invalid_password} ->
        service_notice(user, "Invalid password for \x02#{recovery_nickname(arguments)}\x02.")

      {:error, :authentication_failed} ->
        service_notice(user, "Authentication failed. Invalid password or nickname.")

      {:error, "UNAVAILABLE", _message} = error ->
        error

      {:error, _reason} ->
        service_notice(user, "Service recovery is temporarily unavailable.")
    end
  end

  defp deferred_recovery_job(verb, arguments, user, runtime) when verb in @recovery_commands do
    with {:ok, nickname, password} <- recovery_arguments(verb, arguments),
         {:ok, registered_nick, verified_account} <-
           prepare_recovery_authentication(nickname, password, user) do
      {:deferred_transaction,
       fn ->
         with :ok <- commit_recovery_verification_if_needed(verified_account) do
           recovery_operation(verb, registered_nick, user, runtime)
         end
       end}
    else
      {:error, :syntax, messages} ->
        service_notice_messages("NickServ", user, messages)

      {:error, :registered_nick_not_found} ->
        service_notice(user, "Nick \x02#{recovery_nickname(arguments)}\x02 is not registered.")

      {:error, :secure_required} ->
        service_notice(user, "This account requires a secure TLS connection for password authentication.")

      {:error, :password_required} ->
        recovery_password_required(verb, user, recovery_nickname(arguments))

      {:error, :invalid_password} ->
        service_notice(user, "Invalid password for \x02#{recovery_nickname(arguments)}\x02.")

      {:error, :authentication_failed} ->
        service_notice(user, "Authentication failed. Invalid password or nickname.")

      {:error, "UNAVAILABLE", _message} = error ->
        error

      {:error, _reason} ->
        service_notice(user, "Service recovery is temporarily unavailable.")
    end
  end

  defp recovery_arguments(verb, [verb, nickname]) when is_binary(nickname), do: {:ok, nickname, nil}

  defp recovery_arguments(verb, [verb, nickname, password])
       when is_binary(nickname) and is_binary(password),
       do: {:ok, nickname, password}

  defp recovery_arguments("GHOST", _arguments),
    do: {:error, :syntax, ["Insufficient parameters for \x02GHOST\x02.", "Syntax: \x02GHOST <nick> [password]\x02"]}

  defp recovery_arguments(verb, _arguments),
    do:
      {:error, :syntax,
       ["Insufficient parameters for \x02#{verb}\x02.", "Syntax: \x02#{verb} <nickname> <password>\x02"]}

  defp recovery_nickname([_verb, nickname | _rest]) when is_binary(nickname), do: nickname
  defp recovery_nickname(_arguments), do: "*"

  defp authenticate_recovery(nickname, password, user) do
    with {:ok, registered_nick, verified_account} <- prepare_recovery_authentication(nickname, password, user),
         :ok <- commit_recovery_verification_if_needed(verified_account) do
      {:ok, registered_nick}
    end
  rescue
    _ -> {:error, :authentication_failed}
  end

  defp prepare_recovery_authentication(nickname, password, user) do
    with {:ok, registered_nick, account_nick} <- recovery_accounts(nickname),
         :ok <- secure_account_allowed?(account_nick, user),
         {:ok, verified_account} <-
           verify_recovery_credentials_without_commit(registered_nick, account_nick, password, user) do
      {:ok, registered_nick, verified_account}
    end
  end

  defp recovery_accounts(nickname) do
    Memento.transaction!(fn ->
      with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(nickname),
           {:ok, account_nick} <- RegisteredNicks.get_by_nickname(registered_nick.account_name) do
        {:ok, registered_nick, account_nick}
      end
    end)
  end

  defp verify_recovery_credentials_without_commit(
         registered_nick,
         account_nick,
         password,
         %User{identified_as: account_name}
       )
       when is_binary(account_name) do
    if CaseMapping.normalize(registered_nick.account_name) == CaseMapping.normalize(account_name),
      do: {:ok, nil},
      else: verify_recovery_password_without_commit(registered_nick, account_nick, password)
  end

  defp verify_recovery_credentials_without_commit(registered_nick, account_nick, password, _user) do
    verify_recovery_password_without_commit(registered_nick, account_nick, password)
  end

  defp verify_recovery_password_without_commit(_registered_nick, _account_nick, nil),
    do: {:error, :password_required}

  defp verify_recovery_password_without_commit(_registered_nick, account_nick, password) do
    case Password.verify_without_upgrade(account_nick, password) do
      {:ok, upgraded_account} -> {:ok, upgraded_account}
      :error -> {:error, :invalid_password}
    end
  end

  defp commit_recovery_verification_if_needed(nil), do: :ok

  defp commit_recovery_verification_if_needed(verified_account),
    do: commit_recovery_verification(verified_account)

  defp commit_recovery_verification(verified_account) do
    Memento.transaction!(fn ->
      with {:ok, current} <- RegisteredNicks.get_by_nickname_for_update(verified_account.nickname),
           true <- current.password_hash == verified_account.password_hash,
           true <- current.account_id == verified_account.account_id do
        _ = RegisteredNicks.update(current, identity_verification_attrs(current, verified_account))
        :ok
      else
        false -> {:error, :authentication_failed}
        {:error, :registered_nick_not_found} -> {:error, :authentication_failed}
      end
    end)
  end

  defp recovery_operation("GHOST", registered_nick, user, runtime) do
    case online_projection(runtime, registered_nick.nickname) do
      nil ->
        service_notice(user, "Nick \x02#{registered_nick.nickname}\x02 is not online.")

      {uid, _projection} when uid == user.uid ->
        service_notice(user, "You cannot ghost yourself.")

      {uid, projection} ->
        owner_action(
          runtime,
          projection,
          %{
            "action" => "kill",
            "target_uid" => uid,
            "value" => nil,
            "reason" => "Killed (#{user.nick} (GHOST command used))"
          },
          service_notice_payload("NickServ", user, ["User \x02#{registered_nick.nickname}\x02 has been disconnected."])
        )
    end
  end

  defp recovery_operation("RECOVER", registered_nick, user, runtime) do
    duration = recovery_duration()

    case online_projection(runtime, registered_nick.nickname) do
      {uid, _projection} when uid == user.uid ->
        service_notice(user, "You cannot recover your own session.")

      {uid, projection} ->
        owner_action(
          runtime,
          projection,
          %{
            "action" => "kill",
            "target_uid" => uid,
            "value" => nil,
            "reason" => "Killed (#{user.nick} (RECOVER command used))"
          },
          recovery_success_payload(user, registered_nick.nickname, duration),
          follow_up: reserve_follow_up(registered_nick.nickname, duration)
        )

      nil ->
        follow_up_result(
          recovery_success_payload(user, registered_nick.nickname, duration),
          reserve_follow_up(registered_nick.nickname, duration)
        )
    end
  end

  defp recovery_operation("REGAIN", registered_nick, user, runtime) do
    duration = regain_duration()

    case online_projection(runtime, registered_nick.nickname) do
      {uid, _projection} when uid == user.uid ->
        service_notice(user, "You cannot regain your own session.")

      {uid, projection} ->
        owner_action(
          runtime,
          projection,
          %{
            "action" => "kill",
            "target_uid" => uid,
            "value" => nil,
            "reason" => "Killed (#{user.nick} (REGAIN command used))"
          },
          regain_reserved_payload(user, registered_nick.nickname, duration),
          follow_up: reserve_follow_up(registered_nick.nickname, duration)
        )

      nil ->
        case runtime.users[user.uid] do
          %{} = projection ->
            owner_action(
              runtime,
              projection,
              %{
                "action" => "nick",
                "target_uid" => user.uid,
                "value" => %{"nick" => registered_nick.nickname},
                "reason" => "NickServ REGAIN"
              },
              service_notice_payload("NickServ", user, [
                "You have regained the nickname \x02#{registered_nick.nickname}\x02."
              ])
            )

          _ ->
            service_notice(user, "Your session is no longer available.")
        end
    end
  end

  defp recovery_operation("RELEASE", registered_nick, user, _runtime) do
    if reservation_active?(registered_nick) do
      payload =
        service_notice_payload("NickServ", user, ["Nick \x02#{registered_nick.nickname}\x02 has been released."])

      follow_up_result(payload, clear_reservation_follow_up(registered_nick))
    else
      service_notice(user, "Nick \x02#{registered_nick.nickname}\x02 is not being held.")
    end
  end

  defp recovery_operation(_verb, _registered_nick, _user, _runtime),
    do: {:reply, "UNSUPPORTED", Requests.error_payload("UNSUPPORTED", "service command is not enabled")}

  defp owner_action(runtime, projection, args, success_payload, options \\ []) do
    {:owner_action,
     owner_action_map(runtime, projection, args, Keyword.put(options, :success_payload, success_payload))}
  end

  defp owner_action_map(runtime, projection, args, options) do
    guards =
      service_guards_for_projection(projection, runtime)
      |> Map.merge(%{
        "target_join_id" => get_in(args, ["value", "join_id"]),
        "channel" => get_in(args, ["value", "channel"])
      })

    %{
      target_sid: get_in(projection, ["home", "sid"]),
      actor: Keyword.get(options, :actor, %{"service" => "NickServ"}),
      method: Keyword.get(options, :method, "user_action"),
      args: args,
      guards: guards,
      ttl_ms: Keyword.get(options, :ttl_ms, 15_000),
      success_payload: Keyword.get(options, :success_payload, Requests.ok_payload(nil)),
      follow_up: Keyword.get(options, :follow_up),
      pre_rows: Keyword.get(options, :pre_rows, [])
    }
  end

  @doc "Completes NickServ verification at the authority before any owner binding."
  @spec verify_job([String.t()], User.t(), map()) :: term()
  def verify_job(["VERIFY", nickname, code], user, runtime)
      when is_binary(nickname) and is_binary(code) do
    result =
      Memento.transaction!(fn ->
        case verify_transaction(nickname, code) do
          {:verified, registered_nick} ->
            with {:ok, row} <- policy_change(runtime),
                 {:ok, account_nick} <- verified_account(registered_nick) do
              {:verified, registered_nick, List.wrap(row), account_nick}
            else
              reason -> Memento.Transaction.abort({:verification_publication_failed, reason})
            end

          {:pending_verified, updated} ->
            case policy_change(runtime) do
              {:ok, row} -> {:pending_verified, updated, List.wrap(row)}
              {:error, reason} -> Memento.Transaction.abort({:policy_projection_failed, reason})
            end

          other ->
            other
        end
      end)

    case result do
      {:notice, messages} ->
        service_notice_messages("NickServ", user, messages)

      {:verified, registered_nick, pre_rows, account_nick} ->
        payload = service_notice_payload("NickServ", user, ["Nickname #{nickname} has been successfully verified."])

        if CaseMapping.normalize(user.nick || "") == registered_nick.nickname_key do
          owner_action(
            runtime,
            runtime.users[user.uid],
            %{
              "action" => "account",
              "target_uid" => user.uid,
              "value" => %{
                "binding" => %{
                  "account_id" => account_nick.account_id,
                  "auth_epoch" => account_nick.auth_epoch,
                  "policy_epoch" => runtime.policy.epoch
                },
                "response_request_id" => nil
              },
              "reason" => "NickServ VERIFY"
            },
            payload,
            actor: %{"service" => "NickServ"},
            pre_rows: pre_rows
          )
        else
          {:state_rows, payload, pre_rows}
        end

      {:pending_verified, updated, rows} ->
        payload =
          service_notice_payload("NickServ", user, [
            "The email address for nickname #{updated.nickname} has been successfully verified."
          ])

        {:state_rows, payload, rows}

      {:error, status, message} ->
        {:reply, status, Requests.error_payload(status, message)}
    end
  rescue
    _ -> {:reply, "UNKNOWN_OUTCOME", Requests.error_payload("UNKNOWN_OUTCOME", "verification outcome is unavailable")}
  end

  def verify_job(_arguments, user, _runtime),
    do:
      service_notice_messages("NickServ", user, [
        "Insufficient parameters for VERIFY.",
        "Syntax: VERIFY <nickname> <code>"
      ])

  @doc "Detaches the caller's current nickname before sending the new binding to its owner."
  @spec ungroup_job([String.t()], User.t(), map()) :: term()
  def ungroup_job(["UNGROUP"], %User{identified_as: account_name} = user, runtime)
      when is_binary(account_name) do
    result =
      Memento.transaction!(fn ->
        case ungroup_transaction(user) do
          {:ok, detached_nick, account_nick, registered_nick} ->
            with {:ok, row} <- policy_change(runtime),
                 %{} = projection <- runtime.users[user.uid],
                 {:ok, binding} <- account_binding_from_record(runtime, detached_nick) do
              {:ok, detached_nick, account_nick, registered_nick, List.wrap(row), projection, binding}
            else
              reason -> Memento.Transaction.abort({:ungroup_publication_failed, reason})
            end

          other ->
            other
        end
      end)

    case result do
      {:ok, detached_nick, account_nick, registered_nick, pre_rows, projection, binding} ->
        payload =
          service_notice_payload("NickServ", user, [
            "Nick #{registered_nick.nickname} has been removed from account #{account_nick.account_name}.",
            "It is now a separate NickServ account.",
            "Your current session is now identified for #{detached_nick.account_name}."
          ])

        owner_action(
          runtime,
          projection,
          %{
            "action" => "account",
            "target_uid" => user.uid,
            "value" => %{"binding" => binding, "response_request_id" => nil},
            "reason" => "NickServ UNGROUP"
          },
          payload,
          actor: %{"service" => "NickServ"},
          pre_rows: pre_rows
        )

      {:notice, messages} ->
        service_notice_messages("NickServ", user, messages)

      {:error, status, message} ->
        {:reply, status, Requests.error_payload(status, message)}
    end
  rescue
    _ ->
      {:reply, "UNKNOWN_OUTCOME",
       Requests.error_payload("UNKNOWN_OUTCOME", "account separation outcome is unavailable")}
  end

  def ungroup_job(["UNGROUP" | _], user, _runtime),
    do:
      service_notice_messages("NickServ", user, [
        "Too many parameters for UNGROUP.",
        "Syntax: UNGROUP"
      ])

  def ungroup_job(_arguments, user, _runtime),
    do:
      service_notice_messages("NickServ", user, [
        "You must identify to NickServ before using the UNGROUP command.",
        "Use /msg NickServ IDENTIFY <password> to identify."
      ])

  defp ungroup_transaction(%User{nick: nick, identified_as: account_name})
       when is_binary(nick) and is_binary(account_name) do
    with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname_for_update(nick),
         {:ok, account_nick} <- RegisteredNicks.get_by_nickname_for_update(account_name),
         :ok <- ungroup_belongs_to_account(registered_nick, account_nick),
         :ok <- ungroup_account_verified(account_nick),
         :ok <- ungroup_is_alias(registered_nick) do
      source_settings =
        if CaseMapping.normalize(account_nick.settings.display || "") == registered_nick.nickname_key,
          do: Settings.update(account_nick.settings, %{display: nil}),
          else: account_nick.settings

      if source_settings != account_nick.settings do
        _ = RegisteredNicks.update(account_nick, %{settings: source_settings})
      end

      detached_nick =
        RegisteredNicks.update(registered_nick, %{
          account_name: registered_nick.nickname,
          account_id: Identity.new_id(),
          auth_epoch: Identity.auth_epoch(),
          password_hash: account_nick.password_hash,
          scram_sha_256: account_nick.scram_sha_256,
          email: account_nick.email,
          verify_code: nil,
          verified_at: account_nick.verified_at,
          last_seen_at: DateTime.utc_now(),
          settings: Settings.update(source_settings, %{display: nil})
        })

      {:ok, detached_nick, account_nick, registered_nick}
    else
      {:error, :registered_nick_not_found} when nick == account_name ->
        {:notice, ["Your account could not be resolved. Please try identifying again."]}

      {:error, :registered_nick_not_found} ->
        {:notice, ["Nick #{nick} is not registered."]}

      {:error, :different_account} ->
        {:notice, ["Nick #{nick} does not belong to your account."]}

      {:error, :unverified_account} ->
        {:notice,
         [
           "Your account #{account_name} has not been verified yet.",
           "Please verify it first with /msg NickServ VERIFY #{account_name} <code>"
         ]}

      {:error, :primary_nickname} ->
        {:notice, ["You cannot ungroup the primary nickname of your account."]}
    end
  end

  defp ungroup_transaction(_user),
    do: {:error, "REJECTED", "account separation requires an identified nickname"}

  defp ungroup_belongs_to_account(registered_nick, account_nick) do
    if registered_nick.account_name_key == account_nick.nickname_key,
      do: :ok,
      else: {:error, :different_account}
  end

  defp ungroup_account_verified(%{verify_code: nil}), do: :ok
  defp ungroup_account_verified(_account_nick), do: {:error, :unverified_account}

  defp ungroup_is_alias(%{nickname_key: nickname_key, account_name_key: account_name_key})
       when nickname_key != account_name_key,
       do: :ok

  defp ungroup_is_alias(_registered_nick), do: {:error, :primary_nickname}

  defp account_binding_from_record(runtime, account) do
    with true <- is_binary(account.account_id) and is_integer(account.auth_epoch) and account.auth_epoch > 0,
         true <- is_binary(runtime.policy.epoch) do
      {:ok,
       %{
         "account_id" => account.account_id,
         "auth_epoch" => account.auth_epoch,
         "policy_epoch" => runtime.policy.epoch
       }}
    else
      _ -> {:error, "UNAVAILABLE", "account policy is unavailable"}
    end
  end

  defp verify_transaction(nickname, code) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:error, :registered_nick_not_found} ->
        {:notice, ["Nickname #{nickname} is not registered."]}

      {:ok, registered_nick} ->
        cond do
          is_binary(registered_nick.pending_email_verify_code) and
              not ElixIRCd.Utils.Nickserv.pending_email_active?(registered_nick) ->
            RegisteredNicks.update(registered_nick, %{
              pending_email: nil,
              pending_email_verify_code: nil,
              pending_email_requested_at: nil
            })

            {:notice, ["The pending email change for nickname #{registered_nick.nickname} has expired."]}

          is_binary(registered_nick.pending_email_verify_code) ->
            if registered_nick.pending_email_verify_code == code do
              updated =
                RegisteredNicks.update(registered_nick, %{
                  email: registered_nick.pending_email,
                  pending_email: nil,
                  pending_email_verify_code: nil,
                  pending_email_requested_at: nil,
                  last_seen_at: DateTime.utc_now()
                })

              {:pending_verified, updated}
            else
              {:notice, ["Verification failed. Invalid code for nickname #{registered_nick.nickname}."]}
            end

          not is_nil(registered_nick.verified_at) ->
            {:notice, ["Nickname #{registered_nick.nickname} is already verified."]}

          is_nil(registered_nick.verify_code) ->
            {:notice, ["Nickname #{registered_nick.nickname} does not require verification."]}

          registered_nick.verify_code != code ->
            {:notice, ["Verification failed. Invalid code for nickname #{registered_nick.nickname}."]}

          true ->
            {:verified,
             RegisteredNicks.update(registered_nick, %{
               verify_code: nil,
               verified_at: DateTime.utc_now(),
               last_seen_at: DateTime.utc_now()
             })}
        end
    end
  end

  defp verified_account(%{account_name: account_name}) do
    Memento.transaction!(fn ->
      case RegisteredNicks.get_by_nickname(account_name) do
        {:ok, account} -> {:ok, account}
        {:error, :registered_nick_not_found} -> {:error, "STALE", "verification account is unavailable"}
      end
    end)
  end

  @doc "Builds one guarded ChanServ KICK owner action from the authority projection."
  @spec chanserv_kick_job([String.t()], User.t(), map()) :: term()
  def chanserv_kick_job(["KICK", channel_name, target_nick | reason_parts], user, runtime)
      when is_binary(channel_name) and is_binary(target_nick) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         {:ok, channel} <- runtime_channel(runtime, channel_name),
         :ok <- ChannelFlags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, target_uid, target_projection} <- status_target(runtime, target_nick),
         {:ok, membership} <- status_membership(runtime, target_uid, channel_name),
         {:ok, target_user} <- caller_user(runtime, target_uid),
         :ok <- chanserv_peace_check(registered_channel, user, target_user, access_entries) do
      reason = if reason_parts == [], do: "Requested by #{user.nick}", else: Enum.join(reason_parts, " ")
      target_name = target_projection["effective_nick"] || target_projection["requested_nick"] || target_nick

      owner_action(
        runtime,
        target_projection,
        %{
          "action" => "kick",
          "target_uid" => target_uid,
          "value" => %{"channel" => channel.ref, "join_id" => membership.entry["join_id"]},
          "reason" => reason
        },
        service_notice_payload("ChanServ", user, [
          "Kicked #{target_name} from #{channel.ref["name"]}."
        ]),
        actor: %{"service" => "ChanServ"}
      )
    else
      {:error, :registered_channel_not_found} ->
        service_notice("ChanServ", user, "Channel #{channel_name} is not registered.")

      {:error, "UNAVAILABLE", _message} = error ->
        error

      {:error, :channel_not_in_use} ->
        service_notice("ChanServ", user, "Channel #{channel_name} is not currently in use.")

      {:error, :access_denied} ->
        service_notice("ChanServ", user, "Access denied for #{channel_name}.")

      {:error, "NOT_FOUND", _message} ->
        service_notice("ChanServ", user, "Nickname #{target_nick} is not online.")

      {:error, "STALE", message} ->
        service_notice("ChanServ", user, message)

      {:error, :peace_denied} ->
        service_notice(
          "ChanServ",
          user,
          "Channel #{channel_name} has PEACE enabled; you cannot kick a matching protected target."
        )

      {:error, message} when is_binary(message) ->
        service_notice("ChanServ", user, message)
    end
  end

  def chanserv_kick_job(_arguments, user, _runtime),
    do:
      service_notice_messages("ChanServ", user, [
        "Insufficient parameters for KICK.",
        "Syntax: KICK <channel> <nickname|mask> [reason]"
      ])

  @doc "Builds one owner-delivery ChanServ INVITE operation."
  @spec chanserv_invite_job([String.t()], User.t(), map()) :: term()
  def chanserv_invite_job(["INVITE", channel_name], user, runtime),
    do: chanserv_invite_job(["INVITE", channel_name, user.nick], user, runtime)

  def chanserv_invite_job(["INVITE", channel_name, target_nick], user, runtime)
      when is_binary(channel_name) and is_binary(target_nick) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         {:ok, channel} <- runtime_channel(runtime, channel_name),
         :ok <- ChannelFlags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, target_uid, target_projection} <- status_target(runtime, target_nick),
         {:error, "REJECTED", _message} <- runtime_membership(runtime, target_uid, channel_name) do
      target_name = target_projection["effective_nick"] || target_projection["requested_nick"] || target_nick
      invite_id = Identity.nonce()

      owner_action(
        runtime,
        target_projection,
        %{
          "invite_id" => invite_id,
          "inviter_uid" => user.uid,
          "target_uid" => target_uid,
          "channel" => channel.ref,
          "expires_ms" => 0
        },
        service_notice_payload("ChanServ", user, [
          "#{target_name} has been invited to #{channel.ref["name"]}."
        ]),
        actor: %{"service" => "ChanServ"},
        method: "invite"
      )
    else
      {:error, :registered_channel_not_found} ->
        service_notice("ChanServ", user, "Channel #{channel_name} is not registered.")

      {:error, :channel_not_in_use} ->
        service_notice("ChanServ", user, "Channel #{channel_name} is not currently in use.")

      {:error, :access_denied} ->
        service_notice("ChanServ", user, "Access denied for #{channel_name}.")

      {:error, "NOT_FOUND", _message} ->
        service_notice("ChanServ", user, "The nickname #{target_nick} is not online.")

      {:ok, _membership} ->
        service_notice("ChanServ", user, "#{target_nick} is already on #{channel_name}.")

      {:error, "UNAVAILABLE", _message} = error ->
        error

      {:error, message} when is_binary(message) ->
        service_notice("ChanServ", user, message)
    end
  end

  def chanserv_invite_job(_arguments, user, _runtime),
    do: service_notice(user, "Syntax: INVITE <channel> [nickname]")

  @doc "Registers a live global channel from the authority runtime projection."
  @spec chanserv_register_job([String.t()], User.t(), map()) ::
          {:ok, map(), [map()]} | {:error, String.t(), String.t()}
  def chanserv_register_job(["REGISTER", channel_name, password], user, runtime)
      when is_binary(channel_name) and is_binary(password) do
    config = Application.fetch_env!(:elixircd, :services)[:chanserv]

    with :ok <- chanserv_registration_arguments(channel_name, password, config),
         true <- is_binary(user.identified_as),
         {:ok, _channel} <- runtime_channel(runtime, channel_name),
         {:ok, membership} <- status_membership(runtime, user.uid, channel_name),
         true <- runtime_operator?(runtime, channel_name, user.uid, membership.entry["join_id"]) do
      password_hash = Argon2.hash_pwd_salt(password)
      chanserv_register_job(["REGISTER", channel_name, password], user, runtime, password_hash)
    else
      {:error, status, message} -> {:error, status, message}
      false -> {:error, "REJECTED", "you must be identified and be a channel operator"}
      {:error, message} when is_binary(message) -> {:error, "REJECTED", message}
    end
  end

  def chanserv_register_job(_arguments, _user, _runtime),
    do: {:error, "REJECTED", "Syntax: REGISTER <channel> <password>"}

  defp chanserv_register_job(
         ["REGISTER", channel_name, _password],
         user,
         runtime,
         password_hash
       )
       when is_binary(channel_name) and is_binary(password_hash) do
    config = Application.fetch_env!(:elixircd, :services)[:chanserv]

    Memento.transaction!(fn ->
      with {:error, :registered_channel_not_found} <- RegisteredChannels.get_by_name(channel_name),
           :ok <- registered_channel_limit(user.identified_as, config[:max_registered_channels_per_user]),
           {:ok, channel} <- runtime_channel(runtime, channel_name) do
        topic = runtime_topic(channel)

        RegisteredChannels.create(%{
          name: channel.ref["name"],
          founder: user.identified_as,
          password_hash: password_hash,
          registered_by: user_mask(user),
          topic: topic,
          settings: RegisteredChannel.Settings.new(%{persistent_topic: topic_text(topic)})
        })

        {:ok,
         service_notice_payload("ChanServ", user, [
           "Channel #{channel.ref["name"]} has been registered under your account #{user.identified_as}.",
           "Password accepted.",
           "Remember your password so that you can identify to ChanServ and make changes later!"
         ]), []}
      else
        {:ok, _registered_channel} ->
          {:error, "REJECTED", "channel is already registered"}

        {:error, status, message} ->
          {:error, status, message}
      end
    end)
  end

  defp prepare_chanserv_register(["REGISTER", channel_name, password])
       when is_binary(channel_name) and is_binary(password) do
    config = Application.fetch_env!(:elixircd, :services)[:chanserv]

    with :ok <- chanserv_registration_arguments(channel_name, password, config) do
      {:ok, Argon2.hash_pwd_salt(password)}
    end
  end

  defp prepare_chanserv_register(_arguments),
    do: {:error, "REJECTED", "Syntax: REGISTER <channel> <password>"}

  defp chanserv_registration_arguments(channel_name, password, config) do
    cond do
      not channel_name?(channel_name) or String.starts_with?(channel_name, "&") ->
        {:error, "REJECTED", "invalid channel name"}

      String.length(password) < config[:min_password_length] ->
        {:error, "REJECTED", "password is too short"}

      Enum.any?(config[:forbidden_channel_names], &forbidden_channel_name?(&1, channel_name)) ->
        {:error, "REJECTED", "channel name is forbidden"}

      true ->
        :ok
    end
  end

  defp forbidden_channel_name?(%Regex{} = pattern, channel_name), do: Regex.match?(pattern, channel_name)
  defp forbidden_channel_name?(pattern, channel_name) when is_binary(pattern), do: pattern == channel_name
  defp forbidden_channel_name?(_pattern, _channel_name), do: false

  defp registered_channel_limit(_account_name, nil), do: :ok

  defp registered_channel_limit(account_name, max_channels) when is_integer(max_channels) do
    if length(RegisteredChannels.get_by_founder(account_name)) < max_channels,
      do: :ok,
      else: {:error, "REJECTED", "maximum registered channel limit reached"}
  end

  defp registered_channel_limit(_account_name, _max_channels), do: :ok

  defp runtime_operator?(runtime, channel_name, uid, join_id) do
    key = CaseMapping.normalize(channel_name)
    get_in(runtime.channels, [key, :statuses, {uid, join_id, "o"}, :value, :enabled]) == true
  end

  defp runtime_topic(%{registers: %{"topic" => %{value: %{"text" => text, "setter" => setter, "set_ms" => set_ms}}}})
       when is_binary(text) and is_binary(setter) and is_integer(set_ms) do
    %Channel.Topic{text: text, setter: setter, set_at: DateTime.from_unix!(max(set_ms, 0), :millisecond)}
  end

  defp runtime_topic(_channel), do: nil

  defp topic_text(nil), do: nil
  defp topic_text(%Channel.Topic{text: text}), do: text

  @doc "Executes the authority-owned persistent ChanServ ban register."
  @spec chanserv_list_job(String.t(), [String.t()], User.t(), map()) ::
          {:ok, map(), [map()]} | {:error, String.t(), String.t()}
  def chanserv_list_job("BAN", ["BAN", channel_name, target], user, runtime)
      when is_binary(channel_name) and is_binary(target) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         {:ok, channel} <- runtime_channel(runtime, channel_name),
         :ok <- ChannelFlags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         mask <- list_mask(runtime, target),
         {:error, :channel_ban_not_found} <-
           Memento.transaction!(fn ->
             ChannelBans.get_by_channel_name_key_and_mask(channel_key(channel_name), mask)
           end),
         record <-
           Memento.transaction!(fn ->
             ChannelBans.create(%{channel_name_key: channel_key(channel_name), mask: mask, setter: user_mask(user)})
           end) do
      row = channel_list_row(channel.ref, "b", mask, true, record.setter, record.created_at, runtime)

      {:ok,
       service_notice_payload("ChanServ", user, [
         "Ban #{mask} has been added to #{channel.ref["name"]}."
       ]), [row]}
    else
      {:error, :registered_channel_not_found} ->
        {:error, "NOT_FOUND", "channel is not registered"}

      {:error, "channel is not currently in use"} ->
        {:error, "NOT_FOUND", "channel is not currently in use"}

      {:error, :access_denied} ->
        {:error, "REJECTED", "access denied"}

      {:ok, _existing} ->
        {:error, "REJECTED", "ban is already set"}

      {:error, status, message} ->
        {:error, status, message}
    end
  end

  def chanserv_list_job("UNBAN", ["UNBAN", channel_name], user, runtime),
    do: chanserv_list_job("UNBAN", ["UNBAN", channel_name, user.nick], user, runtime)

  def chanserv_list_job("UNBAN", ["UNBAN", channel_name, target], user, runtime)
      when is_binary(channel_name) and is_binary(target) do
    with {:ok, registered_channel, access_entries} <- registered_channel_context(channel_name),
         {:ok, channel} <- runtime_channel(runtime, channel_name),
         :ok <- ChannelFlags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         masks <- matching_bans(runtime, channel_name, target),
         false <- masks == [],
         records <-
           Memento.transaction!(fn ->
             Enum.flat_map(masks, fn mask ->
               ChannelBans.get_by_channel_name_key_and_mask(channel_key(channel_name), mask)
               |> case do
                 {:ok, record} ->
                   ChannelBans.delete(record)
                   [record]

                 _ ->
                   []
               end
             end)
           end) do
      rows =
        Enum.map(records, &channel_list_row(channel.ref, "b", &1.mask, false, &1.setter, DateTime.utc_now(), runtime))

      {:ok,
       service_notice_payload("ChanServ", user, [
         "Removed #{length(records)} ban #{if(length(records) == 1, do: "entry", else: "entries")} from #{channel.ref["name"]}."
       ]), rows}
    else
      {:error, :registered_channel_not_found} ->
        {:error, "NOT_FOUND", "channel is not registered"}

      {:error, "channel is not currently in use"} ->
        {:error, "NOT_FOUND", "channel is not currently in use"}

      {:error, :access_denied} ->
        {:error, "REJECTED", "access denied"}

      false ->
        {:ok,
         service_notice_payload("ChanServ", user, [
           "No matching bans were found on #{channel_name}."
         ]), []}

      {:error, status, message} ->
        {:error, status, message}
    end
  end

  def chanserv_list_job(_verb, _arguments, _user, _runtime),
    do: {:error, "REJECTED", "invalid channel list command"}

  defp channel_key(channel_name), do: CaseMapping.normalize(channel_name)

  defp list_mask(runtime, target) do
    case status_target(runtime, target) do
      {:ok, target_uid, _projection} ->
        case caller_user(runtime, target_uid) do
          {:ok, target_user} -> normalize_mask(user_mask(target_user))
          _ -> normalize_mask(target)
        end

      _ ->
        normalize_mask(target)
    end
  end

  defp matching_bans(runtime, channel_name, target) do
    bans =
      Memento.transaction!(fn ->
        ChannelBans.get_by_channel_name_key(channel_key(channel_name))
      end)

    case status_target(runtime, target) do
      {:ok, target_uid, _projection} ->
        case caller_user(runtime, target_uid) do
          {:ok, target_user} ->
            Enum.filter(bans, &ElixIRCd.Utils.Protocol.match_user_mask?(target_user, &1.mask)) |> Enum.map(& &1.mask)

          _ ->
            Enum.filter(bans, &(&1.mask == normalize_mask(target))) |> Enum.map(& &1.mask)
        end

      _ ->
        mask = normalize_mask(target)
        Enum.filter(bans, &(&1.mask == mask)) |> Enum.map(& &1.mask)
    end
  end

  defp channel_list_row(ref, mode, mask, present, set_by, %DateTime{} = created_at, runtime) do
    set_ms = max(DateTime.to_unix(created_at, :millisecond), 1)
    stamp = stored_list_stamp(ref, mode, mask, present, runtime)

    %{
      "kind" => "channel.list",
      "channel" => ref,
      "mode" => mode,
      "mask" => mask,
      "present" => present,
      "set_by" => set_by,
      "set_ms" => set_ms,
      "stamp" => stamp
    }
  end

  defp stored_list_stamp(ref, mode, mask, true, runtime) do
    key = CaseMapping.normalize(ref["name"] || "")

    record = read_list_record(key, mode, mask)

    case record do
      {:ok, %{stamp: stamp}} when is_list(stamp) -> stamp
      _ -> Output.next_stamp(runtime.sid, runtime.boot)
    end
  end

  defp stored_list_stamp(ref, mode, mask, false, runtime) do
    key = CaseMapping.normalize(ref["name"] || "")

    case read_list_tombstone(key, mode, mask) do
      %{stamp: stamp} when is_list(stamp) -> stamp
      _ -> Output.next_stamp(runtime.sid, runtime.boot)
    end
  end

  defp read_list_record(key, mode, mask) do
    read_in_transaction(fn ->
      case mode do
        "b" -> ChannelBans.get_by_channel_name_key_and_mask(key, mask)
        "e" -> ChannelExcepts.get_by_channel_name_key_and_mask(key, mask)
        "I" -> ChannelInvexes.get_by_channel_name_key_and_mask(key, mask)
        _ -> {:error, :unknown_mode}
      end
    end)
  end

  defp read_list_tombstone(key, mode, mask),
    do: read_in_transaction(fn -> ChannelListTombstones.get(key, mode, mask) end)

  defp read_in_transaction(fun) when is_function(fun, 0) do
    if Memento.Transaction.inside?(), do: fun.(), else: Memento.transaction!(fun)
  end

  defp runtime_membership(runtime, uid, channel_name) do
    case status_membership(runtime, uid, channel_name) do
      {:ok, membership} -> {:ok, membership}
      {:error, _message} -> {:error, "REJECTED", "target is not on the channel"}
    end
  end

  defp chanserv_peace_check(channel, user, target_user, access_entries) do
    denied =
      Map.get(channel.settings, :peace, false) and is_binary(target_user.identified_as) and
        user.identified_as != target_user.identified_as and
        not ChannelFlags.founder?(channel, user.identified_as) and
        ChannelFlags.access_rank(channel, target_user.identified_as, access_entries) >=
          ChannelFlags.access_rank(channel, user.identified_as, access_entries)

    if denied, do: {:error, :peace_denied}, else: :ok
  end

  defp follow_up_result(payload, follow_up), do: {:follow_up, payload, follow_up}

  defp online_projection(runtime, nickname) do
    key = CaseMapping.normalize(nickname)

    Enum.find_value(runtime.users, fn {uid, projection} ->
      if CaseMapping.normalize(projection["requested_nick"] || "") == key or
           CaseMapping.normalize(projection["effective_nick"] || "") == key,
         do: {uid, projection}
    end)
  end

  defp service_guards_for_projection(projection, runtime) do
    %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => projection["rev"],
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => runtime.policy.epoch,
      "policy_revision" => runtime.policy.revision
    }
  end

  defp recovery_success_payload(user, nickname, duration) do
    service_notice_payload("NickServ", user, [
      "Nick \x02#{nickname}\x02 has been recovered.",
      "The nick will be held for you for #{duration} seconds.",
      "To use it, type: \x02/msg NickServ IDENTIFY #{nickname} <password>\x02",
      "followed by: \x02/NICK #{nickname}\x02"
    ])
  end

  defp regain_reserved_payload(user, nickname, duration) do
    service_notice_payload("NickServ", user, [
      "Nick \x02#{nickname}\x02 has been regained and reserved for you for \x02#{duration} seconds\x02.",
      "Use \x02/NICK #{nickname}\x02 to take it (identify first with \x02/msg NickServ IDENTIFY #{nickname} <password>\x02 if needed)."
    ])
  end

  defp reserve_follow_up(nickname, duration),
    do: %{"kind" => "reserve_nick", "nickname" => nickname, "expires_at_ms" => Identity.now_ms() + duration * 1_000}

  defp clear_reservation_follow_up(registered_nick),
    do: %{
      "kind" => "clear_nick_reservation",
      "nickname" => registered_nick.nickname,
      "expected_expires_at_ms" => DateTime.to_unix(registered_nick.reserved_until, :millisecond)
    }

  defp valid_reservation_deadline(expires_at_ms) do
    if Identity.valid_positive?(expires_at_ms) and expires_at_ms > Identity.now_ms(),
      do: :ok,
      else: {:error, "REJECTED", "invalid nickname reservation deadline"}
  end

  defp reserve_nickname(nickname, expires_at_ms) do
    reserved_until = DateTime.from_unix!(expires_at_ms, :millisecond)
    now = DateTime.utc_now()

    with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname_for_update(nickname),
         false <- reservation_active_at?(registered_nick, now) do
      _ = RegisteredNicks.update(registered_nick, %{reserved_until: reserved_until})
      :ok
    else
      true -> {:error, "STALE", "nickname is already reserved"}
      {:error, :registered_nick_not_found} -> {:error, "NOT_FOUND", "nickname is not registered"}
    end
  end

  defp clear_reservation(nickname, expected_expires_at_ms) do
    with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname_for_update(nickname),
         %DateTime{} = reserved_until <- registered_nick.reserved_until,
         ^expected_expires_at_ms <- DateTime.to_unix(reserved_until, :millisecond) do
      _ = RegisteredNicks.update(registered_nick, %{reserved_until: nil})
      :ok
    else
      {:error, :registered_nick_not_found} -> {:error, "NOT_FOUND", "nickname is not registered"}
      _ -> {:error, "STALE", "nickname reservation has changed"}
    end
  end

  defp reservation_active_at?(%{reserved_until: %DateTime{} = reserved_until}, now),
    do: DateTime.compare(reserved_until, now) == :gt

  defp reservation_active_at?(_registered_nick, _now), do: false

  defp reservation_active?(%{reserved_until: %DateTime{} = reserved_until}),
    do: DateTime.compare(reserved_until, DateTime.utc_now()) == :gt

  defp reservation_active?(_registered_nick), do: false

  defp recovery_password_required("GHOST", user, nickname),
    do:
      service_notice_messages("NickServ", user, [
        "You need to provide a password to ghost \x02#{nickname}\x02.",
        "Syntax: \x02GHOST #{nickname} <password>\x02"
      ])

  defp recovery_password_required(verb, user, _nickname),
    do:
      service_notice_messages("NickServ", user, [
        "Insufficient parameters for \x02#{verb}\x02.",
        "Syntax: \x02#{verb} <nickname> <password>\x02"
      ])

  defp recovery_duration,
    do: Application.fetch_env!(:elixircd, :services)[:nickserv][:recover_reservation_duration]

  defp regain_duration,
    do: Application.fetch_env!(:elixircd, :services)[:nickserv][:regain_reservation_duration]

  defp identify_arguments(["IDENTIFY", password], user) when is_binary(password) and is_binary(user.nick),
    do: {:ok, user.nick, password}

  defp identify_arguments(["IDENTIFY", nickname, password], _user)
       when is_binary(nickname) and is_binary(password),
       do: {:ok, nickname, password}

  defp identify_arguments(_arguments, _user),
    do: {:error, "REJECTED", "Syntax: IDENTIFY [nickname] <password>"}

  defp identify_precondition(%User{sasl_authenticated: true, identified_as: account}) when is_binary(account),
    do: {:error, :already_authenticated}

  defp identify_precondition(%User{identified_as: account}) when is_binary(account),
    do: {:error, :same_account}

  defp identify_precondition(_user), do: :ok

  defp secure_account_allowed?(account, user) do
    if Map.get(account.settings, :secure) == true and user.transport not in [:tls, :wss],
      do: {:error, :secure_required},
      else: :ok
  end

  defp account_binding(runtime, account) do
    with true <- is_binary(account.account_id) and is_integer(account.auth_epoch) and account.auth_epoch > 0,
         {:ok, policy_account} <- Policy.get(runtime.policy, "account", account.account_id),
         true <- policy_account["auth_epoch"] == account.auth_epoch do
      {:ok,
       %{
         "account_id" => account.account_id,
         "auth_epoch" => account.auth_epoch,
         "policy_epoch" => runtime.policy.epoch
       }}
    else
      _ -> {:error, "UNAVAILABLE", "account policy is unavailable"}
    end
  end

  defp verify_identity(nickname, password, user) do
    with {:ok, verified_account} <- verify_identity_credentials(nickname, password, user) do
      commit_identity_verification(verified_account, user)
    else
      :error -> :error
      {:error, _status, _message} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_identity_credentials(nickname, password, user) do
    with {:ok, account_nick} <- identity_account(nickname),
         :ok <- secure_account_allowed?(account_nick, user),
         {:ok, verified_account} <- Password.verify_without_upgrade(account_nick, password) do
      {:ok, verified_account}
    else
      :error -> :error
      {:error, _status, _message} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp identity_account(nickname) do
    Memento.transaction!(fn ->
      with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(nickname),
           {:ok, account_nick} <- RegisteredNicks.get_by_nickname(registered_nick.account_name) do
        {:ok, account_nick}
      end
    end)
  rescue
    _ -> :error
  end

  defp commit_identity_verification(verified_account, user) do
    Memento.transaction!(fn ->
      with {:ok, current} <- RegisteredNicks.get_by_nickname_for_update(verified_account.nickname),
           true <- current.password_hash == verified_account.password_hash,
           true <- current.account_id == verified_account.account_id,
           :ok <- secure_account_allowed?(current, user),
           attrs <- identity_verification_attrs(current, verified_account) do
        {:ok, RegisteredNicks.update(current, attrs)}
      else
        false -> {:error, "STALE", "account credentials changed during authentication"}
        {:error, :registered_nick_not_found} -> {:error, "STALE", "account is no longer available"}
        {:error, _reason} = error -> error
      end
    end)
  rescue
    _ -> {:error, "UNKNOWN_OUTCOME", "account authentication could not be committed"}
  end

  defp identity_verification_attrs(current, verified_account) do
    attrs = %{last_seen_at: DateTime.utc_now()}

    if current.scram_sha_256 == verified_account.scram_sha_256,
      do: attrs,
      else: Map.put(attrs, :scram_sha_256, verified_account.scram_sha_256)
  end

  defp target_sid(runtime, uid) do
    case get_in(runtime.users, [uid, "home", "sid"]) do
      sid when is_binary(sid) -> {:ok, sid}
      _ -> {:error, "STALE", "service caller is unavailable"}
    end
  end

  defp service_guards(user, runtime) do
    %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => user.owner_rev,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => runtime.policy.epoch,
      "policy_revision" => runtime.policy.revision
    }
  end

  defp service_notice(user, message) do
    service_notice("NickServ", user, message)
  end

  defp service_notice(service, user, message) do
    service_notice_messages(service, user, [message])
  end

  defp service_notice_messages(service, user, messages) when is_list(messages) do
    payload = service_notice_payload(service, user, messages)

    if Map.has_key?(payload, "items"),
      do: {:reply, "OK", payload},
      else: {:reply, "REJECTED", payload}
  end

  defp service_notice_payload(service, user, messages) when is_list(messages) do
    items =
      Enum.map(messages, fn message ->
        %{
          "command" => "NOTICE",
          "params" => [user.nick || "*"],
          "trailing" => message,
          "source" => %{"service" => service},
          "tags" => %{}
        }
      end)

    if Enum.all?(items, &(Schema.validate_reply_item(&1) == :ok)),
      do: %{"items" => items, "result" => nil},
      else: Requests.error_payload("REJECTED", "invalid service reply")
  end

  defp dispatch(service, arguments, user, runtime) do
    dispatch_messages(
      service,
      runtime,
      policy_mutation?(service, arguments),
      fn -> Service.dispatch(user, service, normalize_command(arguments)) end
    )
  end

  defp dispatch_remote_read(service, operation) when is_function(operation, 0) do
    case dispatch_messages(service, nil, false, operation) do
      {:ok, items, []} -> {:ok, stream_payload(items)}
      {:error, _status, _message} = error -> error
      _ -> {:error, "REJECTED", "service query failed"}
    end
  end

  defp dispatch_messages(service, runtime, mutation?, operation) do
    result =
      Publication.with_policy_refresh_suppressed(fn ->
        Dispatcher.with_s2s_sink(
          fn %Message{} = message ->
            messages = Process.get(@messages_key, [])
            Process.put(@messages_key, [message | messages])
          end,
          fn ->
            Output.transaction(
              fn ->
                # Memento may rerun this callback. Reset the reply accumulator
                # inside the retry boundary so a committed reply never repeats
                # messages from an aborted attempt.
                Process.put(@messages_key, [])

                case operation.() do
                  :ok ->
                    if mutation? do
                      case policy_change(runtime) do
                        {:ok, row} ->
                          {:ok, row}

                        {:error, reason} ->
                          Memento.Transaction.abort({:policy_projection_failed, reason})
                      end
                    else
                      {:ok, nil}
                    end

                  result ->
                    result
                end
              end,
              drain_fun: &Dispatcher.drain_intent/1
            )
          end
        )
      end)

    messages = Process.get(@messages_key, []) |> Enum.reverse()
    Process.delete(@messages_key)

    case result do
      {:ok, policy_row} ->
        items = Enum.map(messages, &reply_item(&1, service))

        if Enum.all?(items, &(Schema.validate_reply_item(&1) == :ok)),
          do: {:ok, items, List.wrap(policy_row)},
          else: {:error, :invalid_reply}

      {:quit, _reason} ->
        {:error, "REJECTED", "service command closed its caller"}

      _ ->
        {:error, "REJECTED", "service command failed"}
    end
  rescue
    _ -> {:error, "REJECTED", "service command failed"}
  end

  defp runtime_online_user(runtime, nickname) when is_binary(nickname) do
    case online_projection(runtime, nickname) do
      {uid, projection} -> {:ok, user_from_projection(Map.put(projection, "uid", uid), runtime)}
      nil -> {:error, :user_not_found}
    end
  end

  defp runtime_online_user(_runtime, _nickname), do: {:error, :user_not_found}

  defp normalize_command([verb | rest]), do: [String.upcase(verb) | rest]
  defp normalize_command(arguments), do: arguments

  defp policy_mutation?("NickServ", [verb | rest]) do
    String.upcase(verb) in ["ACCESS", "DROP", "GROUP", "MEMO", "REGISTER", "SET"] and
      not read_only_nickserv?(String.upcase(verb), rest)
  end

  defp policy_mutation?("ChanServ", [verb | rest]) do
    case String.upcase(verb) do
      "ACCESS" -> not read_only_chanserv_access?(rest)
      "FLAGS" -> length(rest) >= 3
      "SET" -> chanserv_set_mutation?(rest)
      command -> command in ["DROP", "TRANSFER"]
    end
  end

  defp policy_mutation?(_service, _arguments), do: false

  defp read_only_nickserv?("ACCESS", [subcommand | _]), do: String.upcase(subcommand) == "LIST"
  defp read_only_nickserv?("MEMO", [subcommand | _]), do: String.upcase(subcommand) in ["LIST", "READ"]
  defp read_only_nickserv?("SET", []), do: true
  defp read_only_nickserv?(_verb, _arguments), do: false

  defp read_only_chanserv_access?([_channel, subcommand | _]), do: String.upcase(subcommand) == "LIST"
  defp read_only_chanserv_access?(_arguments), do: false

  defp chanserv_set_mutation?([_channel, setting | values]) do
    setting = String.upcase(setting)

    values != [] or setting in ["MLOCK"]
  end

  defp chanserv_set_mutation?(_arguments), do: false

  defp reply_item(%Message{} = message, service) do
    %{
      "command" => Message.command_name(message.command),
      "params" => message.params,
      "trailing" => message.trailing,
      "source" => %{"service" => service},
      "tags" => message.tags
    }
  end

  defp stream_payload([]), do: %{"items" => [], "result" => nil}

  defp stream_payload(items) do
    {:stream, Enum.map(Enum.chunk_every(items, 256), &%{"items" => &1, "result" => nil})}
  end

  defp safe_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_message(reason) when is_binary(reason), do: reason
  defp safe_message(reason), do: inspect(reason)
end
