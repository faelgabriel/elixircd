defmodule ElixIRCd.Server.S2S.Domain do
  @moduledoc """
  Executes the bounded owner-local ENP/1 mutations.

  The manager supplies the authenticated runtime context; this module owns the
  second guard check against the local Mnesia records. Existing C2S handlers
  are reused where they already express the domain transition, while all
  external output remains an `Output` intent until the transaction commits.
  """

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Commands.Nick
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.Runtime
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Nickserv

  import ElixIRCd.Utils.Protocol, only: [user_mask: 2]

  @type effect :: map()
  @type success :: {:ok, map(), [effect()]}
  @type failure :: {:error, String.t(), String.t(), [effect()]}

  @type deferred_success :: {:ok, map(), Output.group() | nil}
  @type deferred_failure :: {:error, String.t(), String.t(), Output.group() | nil}

  @doc "Executes one already-authorized owner-local action or invitation."
  @spec execute(map(), Runtime.t(), map()) :: success() | failure()
  def execute(%{"method" => method} = frame, runtime, context) when method in ["user_action", "invite"] do
    key = {__MODULE__, make_ref()}
    Process.put(key, [])

    try do
      result =
        Output.transaction(
          fn -> execute_in_transaction(frame, runtime, context) end,
          drain_fun: fn intent -> capture(key, intent) end
        )

      effects = Process.get(key, []) |> Enum.reverse()

      case result do
        {:ok, payload, extra_effects} ->
          {:ok, payload, effects ++ normalize_extra_effects(extra_effects)}

        {:error, status, message, extra_effects} ->
          {:error, status, message, effects ++ normalize_extra_effects(extra_effects)}

        {:ok, payload} ->
          {:ok, payload, effects}

        {:error, status, message} ->
          {:error, status, message, effects}

        _ ->
          {:error, "REJECTED", "invalid domain result", effects}
      end
    rescue
      _error ->
        effects = Process.get(key, []) |> Enum.reverse()
        {:error, "REJECTED", "owner operation failed", effects}
    catch
      _kind, _reason ->
        effects = Process.get(key, []) |> Enum.reverse()
        {:error, "REJECTED", "owner operation failed", effects}
    after
      Process.delete(key)
    end
  end

  def execute(_frame, _runtime, _context), do: {:error, "UNSUPPORTED", "owner operation is unavailable", []}

  @doc """
  Executes an owner mutation while leaving its committed output group durable.

  The caller owns the subsequent drain and acknowledgement. Keeping that
  boundary outside this function is what prevents a manager crash between the
  owner transaction and derived publication from losing the committed group.
  """
  @spec execute_deferred(map(), Runtime.t(), map()) :: deferred_success() | deferred_failure()
  def execute_deferred(%{"method" => method} = frame, runtime, context) when method in ["user_action", "invite"] do
    result =
      Output.transaction_deferred(fn ->
        result = execute_in_transaction(frame, runtime, context)

        with :ok <- collect_extra_effects(result) do
          result
        end
      end)

    case result do
      {:ok, {:ok, payload, _extra_effects}, group} ->
        {:ok, payload, group}

      {:ok, {:error, status, message, _extra_effects}, group}
      when is_binary(status) and is_binary(message) ->
        {:error, status, message, group}

      {:ok, {:ok, payload}, group} ->
        {:ok, payload, group}

      {:ok, {:error, status, message}, group}
      when is_binary(status) and is_binary(message) ->
        {:error, status, message, group}

      {:error, reason} ->
        {:error, "REJECTED", safe_deferred_reason(reason), nil}

      _ ->
        {:error, "REJECTED", "invalid owner operation result", nil}
    end
  rescue
    _error -> {:error, "REJECTED", "owner operation failed", nil}
  catch
    _kind, _reason -> {:error, "REJECTED", "owner operation failed", nil}
  end

  def execute_deferred(_frame, _runtime, _context),
    do: {:error, "UNSUPPORTED", "owner operation is unavailable", nil}

  defp capture(key, intent) do
    Process.put(key, [intent | Process.get(key, [])])
    :ok
  end

  defp normalize_extra_effects(effects) do
    Enum.map(effects, fn
      %{"kind" => _kind} = row -> %{kind: :s2s_rows, rows: [row]}
      effect -> effect
    end)
  end

  defp collect_extra_effects({:ok, _payload, effects}), do: collect_effects(effects)
  defp collect_extra_effects(_result), do: :ok

  defp collect_effects(effects) when is_list(effects) do
    Enum.reduce_while(normalize_extra_effects(effects), :ok, fn intent, :ok ->
      case Output.collect_intent(intent) do
        :ok -> {:cont, :ok}
        {:error, reason} -> Memento.Transaction.abort({:output_capacity, reason})
        :inactive -> Memento.Transaction.abort(:output_collection_inactive)
      end
    end)
  end

  defp collect_effects(_effects), do: Memento.Transaction.abort(:invalid_extra_effects)

  defp safe_deferred_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 256)
  defp safe_deferred_reason(reason), do: reason |> inspect() |> String.slice(0, 256)

  defp execute_in_transaction(%{"method" => "user_action", "args" => args} = frame, runtime, context) do
    with {:ok, user} <- target_user(args["target_uid"], runtime),
         :ok <- target_revision_guard(user, args["action"], frame["guards"]),
         :ok <- action_guard(args, frame["guards"]),
         :ok <- actor_guard(frame, runtime, context),
         :ok <- policy_guard(frame["guards"], runtime, args["action"]),
         :ok <- actor_allowed?(frame["actor"], args["action"], args, runtime, context, user) do
      execute_action(args, frame, runtime, user)
    else
      {:error, _status, _message} = error -> error
    end
  end

  defp execute_in_transaction(%{"method" => "invite", "args" => args} = frame, runtime, context) do
    with {:ok, target} <- target_user(args["target_uid"], runtime),
         :ok <- target_revision_guard(target, "invite", frame["guards"]),
         :ok <- actor_guard(frame, runtime, context),
         :ok <- policy_guard(frame["guards"], runtime, "invite"),
         :ok <- invite_actor_guard(frame["actor"], args),
         {:ok, channel} <- exact_channel(args["channel"]),
         :ok <- invite_permission(frame["actor"], args, channel, runtime, context),
         :ok <- target_not_on_channel(target, channel),
         :ok <- valid_expiry(args["expires_ms"]),
         invite <- create_invite(args, target, channel, frame),
         :ok <- notify_invite(invite, target, channel, runtime),
         row <- invite_row(args, channel) do
      {:ok, %{"accepted" => true}, [row]}
    else
      {:error, _status, _message} = error -> error
    end
  end

  defp target_user(uid, runtime) when is_binary(uid) do
    with {:ok, %User{} = user} <- Users.get_by_uid(uid),
         %{"home" => home} <- runtime.users[uid],
         true <- owned_here?(user, home, runtime) do
      {:ok, user}
    else
      {:error, :user_not_found} -> {:error, "NOT_FOUND", "target user is unavailable"}
      false -> {:error, "STALE", "target user is not owned by this boot"}
      _ -> {:error, "STALE", "target user is unavailable"}
    end
  end

  defp target_user(_uid, _runtime), do: {:error, "NOT_FOUND", "target user is unavailable"}

  defp owned_here?(%User{home_sid: home_sid, home_boot: home_boot}, home, runtime) do
    (home_sid || runtime.sid) == runtime.sid and (home_boot || runtime.boot) == runtime.boot and
      home == %{"sid" => runtime.sid, "boot" => runtime.boot}
  end

  defp target_revision_guard(%User{owner_rev: owner_rev}, _action, %{"target_user_rev" => expected})
       when is_integer(expected) and owner_rev == expected,
       do: :ok

  defp target_revision_guard(%User{}, action, %{"target_user_rev" => nil})
       when action in ["kill", "nick", "host", "ident", "account", "oper"],
       do: {:error, "STALE", "target user revision is required"}

  defp target_revision_guard(%User{}, _action, %{"target_user_rev" => nil}), do: :ok

  defp target_revision_guard(_user, _action, _guards), do: {:error, "STALE", "target user revision changed"}

  defp action_guard(%{"action" => action, "value" => %{"channel" => channel, "join_id" => join_id}}, guards)
       when action in ["kick", "part"] do
    if guards["target_join_id"] == join_id and guards["channel"] == channel,
      do: :ok,
      else: {:error, "STALE", "membership guard is missing or changed"}
  end

  defp action_guard(%{"action" => action}, %{"target_user_rev" => revision})
       when action in ["kill", "nick", "host", "ident", "oper", "account"] and is_integer(revision),
       do: :ok

  defp action_guard(_args, _guards), do: :ok

  defp actor_guard(
         %{"actor" => %{"user" => uid}, "guards" => %{"actor_uid" => actor_uid}} = frame,
         runtime,
         context
       )
       when is_binary(uid) and (is_nil(actor_uid) or actor_uid == uid) do
    case runtime.users[uid] do
      %{"home" => %{"sid" => _sid, "boot" => _boot} = home} ->
        if actor_origin_allowed?(runtime, home, frame, context),
          do: :ok,
          else: {:error, "REJECTED", "actor origin does not own actor"}

      _ ->
        {:error, "STALE", "actor user is unavailable"}
    end
  end

  defp actor_guard(
         %{"actor" => %{"service" => service}, "guards" => %{"actor_uid" => nil}} = frame,
         runtime,
         context
       )
       when service in ["NickServ", "ChanServ"] do
    if service_origin_allowed?(runtime, frame, context),
      do: :ok,
      else: {:error, "REJECTED", "service actor is not authoritative"}
  end

  defp actor_guard(
         %{"actor" => %{"server" => sid}, "guards" => %{"actor_uid" => nil}} = frame,
         runtime,
         context
       ) do
    if server_origin_allowed?(runtime, sid, frame, context),
      do: :ok,
      else: {:error, "REJECTED", "server actor does not match origin"}
  end

  defp actor_guard(_frame, _runtime, _context), do: {:error, "REJECTED", "actor guard mismatch"}

  defp actor_origin_allowed?(runtime, home, frame, context) do
    case origin_ref(runtime, frame, context) do
      :absent -> true
      {:ok, origin} -> home == origin and current_node?(runtime, origin)
      :invalid -> false
    end
  end

  defp service_origin_allowed?(runtime, frame, context) do
    case origin_ref(runtime, frame, context) do
      :absent -> true
      {:ok, %{"sid" => sid} = origin} -> sid == runtime.services_authority and current_node?(runtime, origin)
      :invalid -> false
    end
  end

  defp server_origin_allowed?(runtime, sid, frame, context) do
    case origin_ref(runtime, frame, context) do
      {:ok, %{"sid" => ^sid} = origin} -> current_node?(runtime, origin)
      _ -> false
    end
  end

  defp origin_ref(runtime, frame, context) do
    sid = context[:origin_sid] || get_in(frame, ["origin", "sid"])
    boot = context[:origin_boot] || get_in(frame, ["origin", "boot"]) || get_in(runtime.nodes, [sid, "boot"])

    cond do
      is_binary(sid) and is_binary(boot) -> {:ok, %{"sid" => sid, "boot" => boot}}
      is_nil(sid) and is_nil(boot) -> :absent
      true -> :invalid
    end
  end

  defp current_node?(runtime, %{"sid" => sid, "boot" => boot}) do
    case runtime.nodes[sid] do
      %{"boot" => ^boot} -> true
      _ -> sid == runtime.sid and boot == runtime.boot
    end
  end

  defp policy_guard(_guards, _runtime, action) when action != "account", do: :ok

  defp policy_guard(%{"policy_epoch" => nil, "policy_revision" => nil}, _runtime, _action), do: :ok

  defp policy_guard(%{"policy_epoch" => epoch, "policy_revision" => revision}, runtime, _action) do
    if (is_nil(epoch) or epoch == runtime.policy.epoch) and
         (is_nil(revision) or revision == runtime.policy.revision),
       do: :ok,
       else: {:error, "STALE", "policy revision changed"}
  end

  defp actor_allowed?(%{"service" => service}, action, _args, runtime, context, _user)
       when service in ["NickServ", "ChanServ"] and action in ["join", "kick", "part", "host", "ident", "nick", "kill"],
       do:
         if(runtime.services_authority == context[:origin_sid] and is_binary(runtime.services_authority),
           do: :ok,
           else: {:error, "UNAVAILABLE", "service authority is unavailable"}
         )

  defp actor_allowed?(%{"service" => "NickServ"}, "account", _args, runtime, context, _user) do
    if context[:origin_sid] == runtime.services_authority and is_binary(runtime.services_authority),
      do: :ok,
      else: {:error, "UNAVAILABLE", "service authority is unavailable"}
  end

  defp actor_allowed?(%{"user" => actor_uid}, "account", %{"value" => %{"binding" => nil}}, _runtime, _context, user) do
    if actor_uid == user.uid,
      do: :ok,
      else: {:error, "REJECTED", "actor cannot clear target account"}
  end

  defp actor_allowed?(%{"user" => actor_uid}, action, _args, _runtime, context, user)
       when action in ["nick", "host", "ident"],
       do:
         if(actor_uid == user.uid or privileged_context?(context),
           do: :ok,
           else: {:error, "REJECTED", "actor cannot change target"}
         )

  defp actor_allowed?(%{"server" => sid}, "oper", _args, runtime, context, _user) do
    if sid == runtime.services_authority and context[:origin_sid] == sid,
      do: :ok,
      else: {:error, "REJECTED", "operator authority is unavailable"}
  end

  defp actor_allowed?(%{"user" => _actor_uid}, "account", _args, _runtime, _context, _user),
    do: {:error, "REJECTED", "only NickServ may install an account binding"}

  defp actor_allowed?(%{"user" => actor_uid}, "oper", _args, _runtime, context, user) do
    if actor_uid == user.uid and is_binary(context[:operator_role]),
      do: :ok,
      else: {:error, "REJECTED", "operator authority is required"}
  end

  defp actor_allowed?(%{"user" => actor_uid}, "part", _args, _runtime, context, user) do
    if actor_uid == user.uid or privileged_context?(context),
      do: :ok,
      else: {:error, "REJECTED", "actor cannot part target"}
  end

  defp actor_allowed?(actor, "kick", args, runtime, context, _user) do
    with {:ok, channel} <- channel_from_value(args["value"], runtime),
         true <- privileged_context?(context) or actor_operator?(actor, channel, runtime) do
      :ok
    else
      _ -> {:error, "REJECTED", "actor lacks channel privilege"}
    end
  end

  defp actor_allowed?(_actor, "kill", _args, _runtime, context, _user) do
    if privileged_context?(context), do: :ok, else: {:error, "REJECTED", "kill authority is required"}
  end

  defp actor_allowed?(_actor, "join", _args, _runtime, context, _user) do
    if privileged_context?(context), do: :ok, else: {:error, "REJECTED", "forced join requires service authority"}
  end

  defp actor_allowed?(_actor, _action, _args, _runtime, _context, _user),
    do: {:error, "UNSUPPORTED", "owner action is not enabled"}

  defp privileged_context?(context),
    do: is_binary(context[:operator_role]) or context[:local_sid] == context[:services_authority]

  defp execute_action(%{"action" => "kill", "target_uid" => _uid, "reason" => reason}, _frame, _runtime, %User{} = user) do
    reason = decode_bytes(reason) || "remote kill"
    Connection.handle_disconnect(user.pid, user.transport, reason)

    if is_pid(user.pid) do
      Dispatcher.disconnect(user, reason, allow_missing: true)
    end

    {:ok, %{"accepted" => true, "owner_rev" => max(user.owner_rev || 1, 1)}, []}
  end

  defp execute_action(%{"action" => action, "value" => value, "reason" => reason}, frame, runtime, user)
       when action in ["kick", "part"] do
    with {:ok, channel} <- channel_from_value(value, runtime),
         {:ok, membership} <- target_membership(user, channel),
         true <- membership.join_id == value["join_id"],
         :ok <- remove_membership(user, membership, channel, action, decode_bytes(reason), frame["actor"]) do
      {:ok, %{"accepted" => true, "owner_rev" => max(user.owner_rev || 1, 1)}, []}
    else
      false -> {:error, "STALE", "target membership generation changed"}
      {:error, :user_channel_not_found} -> {:error, "NOT_FOUND", "target is not on the channel"}
      {:error, _status, _message} = error -> error
      _ -> {:error, "REJECTED", "membership removal failed"}
    end
  end

  defp execute_action(
         %{"action" => "join", "value" => %{"channel" => channel_name, "key" => key}},
         _frame,
         _runtime,
         user
       ) do
    params = if is_nil(key), do: [decode_bytes(channel_name)], else: [decode_bytes(channel_name), decode_bytes(key)]
    before = UserChannels.get_by_user_pid_and_channel_name(user.pid, hd(params))
    Join.handle(user, %Message{command: "JOIN", params: params})

    case {before, UserChannels.get_by_user_pid_and_channel_name(user.pid, hd(params))} do
      {{:error, :user_channel_not_found}, {:ok, _membership}} ->
        {:ok, %{"accepted" => true, "owner_rev" => max(user.owner_rev || 1, 1)}, []}

      {{:ok, _}, _} ->
        {:error, "REJECTED", "target is already on the channel"}

      _ ->
        {:error, "REJECTED", "forced join was refused"}
    end
  end

  defp execute_action(%{"action" => "nick", "value" => %{"nick" => nick}}, _frame, _runtime, user) do
    Nick.handle(user, %Message{command: "NICK", params: [nick]})

    case Users.get_by_uid(user.uid) do
      {:ok, %User{nick: ^nick} = updated} ->
        {:ok, %{"accepted" => true, "owner_rev" => max(updated.owner_rev || 1, 1)}, []}

      _ ->
        {:error, "REJECTED", "nickname change was refused"}
    end
  end

  defp execute_action(%{"action" => "host", "value" => %{"displayhost" => displayhost}}, _frame, _runtime, user) do
    updated = Users.update(user, %{cloaked_hostname: displayhost})
    {:ok, %{"accepted" => true, "owner_rev" => max(updated.owner_rev || 1, 1)}, []}
  end

  defp execute_action(%{"action" => "ident", "value" => %{"ident" => ident}}, _frame, _runtime, user) do
    if valid_ident?(ident) do
      updated = Users.update(user, %{ident: ident})
      {:ok, %{"accepted" => true, "owner_rev" => max(updated.owner_rev || 1, 1)}, []}
    else
      {:error, "REJECTED", "ident is invalid"}
    end
  end

  defp execute_action(
         %{"action" => "account", "value" => %{"binding" => nil}},
         _frame,
         _runtime,
         %User{identified_as: nil}
       ),
       do: {:error, "REJECTED", "user is not identified"}

  defp execute_action(
         %{"action" => "account", "value" => %{"binding" => nil}},
         _frame,
         _runtime,
         %User{identified_as: account_name} = user
       ) do
    updated = Users.update(user, %{identified_as: nil, sasl_authenticated: false, sasl_attempts: 0})
    updated = Nickserv.sync_registered_mode(updated)
    :ok = publish_account_logout(updated, account_name)
    {:ok, %{"accepted" => true, "owner_rev" => max(updated.owner_rev || 1, 1)}, []}
  end

  defp execute_action(
         %{"action" => "account", "value" => %{"binding" => binding}},
         _frame,
         runtime,
         user
       ) do
    with {:ok, account} <- bound_account(runtime, binding),
         account_name when is_binary(account_name) <- account["canonical_name"],
         updated <-
           Users.update(user, %{
             identified_as: account_name,
             sasl_authenticated: true,
             sasl_attempts: 0
           }),
         updated <- Nickserv.sync_registered_mode(updated),
         :ok <- publish_account_success(updated, account_name) do
      {:ok, %{"accepted" => true, "owner_rev" => max(updated.owner_rev || 1, 1)}, []}
    else
      {:error, :policy_unavailable} -> {:error, "UNAVAILABLE", "account policy is unavailable"}
      {:error, :invalid_binding} -> {:error, "STALE", "account binding is no longer valid"}
      _ -> {:error, "STALE", "account binding is no longer valid"}
    end
  end

  defp execute_action(
         %{"action" => "oper", "value" => %{"enabled" => enabled, "role" => role}},
         _frame,
         _runtime,
         user
       ) do
    case valid_oper_role(enabled, role) do
      :ok ->
        modes = if(enabled, do: Enum.uniq([:o | user.modes]), else: List.delete(user.modes, :o))
        updated = Users.update(user, %{modes: modes})
        publish_oper_change(updated, enabled)
        {:ok, %{"accepted" => true, "owner_rev" => max(updated.owner_rev || 1, 1)}, []}

      {:error, :invalid_oper_role} ->
        {:error, "REJECTED", "operator role is invalid"}
    end
  end

  defp execute_action(%{"action" => action}, _frame, _runtime, _user) when action in ["account", "oper"],
    do: {:error, "UNSUPPORTED", "owner action is not enabled"}

  defp execute_action(_args, _frame, _runtime, _user), do: {:error, "UNSUPPORTED", "owner action is not enabled"}

  defp exact_channel(%{"name" => name} = ref) do
    with {:ok, %Channel{} = channel} <- Channels.get_by_name(name),
         true <- channel_ref_equal?(channel, ref) do
      {:ok, channel}
    else
      {:error, :channel_not_found} -> {:error, "NOT_FOUND", "channel is unavailable"}
      false -> {:error, "STALE", "channel incarnation changed"}
      _ -> {:error, "REJECTED", "channel is unavailable"}
    end
  end

  defp exact_channel(_ref), do: {:error, "NOT_FOUND", "channel is unavailable"}

  defp channel_from_value(%{"channel" => ref}, _runtime), do: exact_channel(ref)
  defp channel_from_value(_value, _runtime), do: {:error, "STALE", "channel guard is missing"}

  defp channel_ref_equal?(%Channel{} = channel, %{"name" => name, "born_ms" => born_ms, "cid" => cid}) do
    channel.name_key == CaseMapping.normalize(name) and
      max(channel.born_ms || DateTime.to_unix(channel.created_at, :millisecond), 1) == born_ms and
      channel.cid == cid
  end

  defp channel_ref_equal?(_channel, _ref), do: false

  defp target_membership(%User{uid: uid, pid: pid}, %Channel{name: name}) do
    channel_key = CaseMapping.normalize(name)

    case UserChannels.get_by_user_pid_and_channel_name(pid, name) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, :user_channel_not_found} ->
        UserChannels.get_by_uid(uid)
        |> Enum.find_value({:error, :user_channel_not_found}, fn
          %UserChannel{channel_name_key: ^channel_key} = membership -> {:ok, membership}
          _ -> false
        end)
    end
  end

  defp target_not_on_channel(%User{uid: uid, pid: pid}, %Channel{name: name}) do
    case UserChannels.get_by_user_pid_and_channel_name(pid, name) do
      {:ok, _membership} ->
        {:error, "REJECTED", "target is already on the channel"}

      {:error, :user_channel_not_found} ->
        if Enum.any?(UserChannels.get_by_uid(uid), &(&1.channel_name_key == CaseMapping.normalize(name))),
          do: {:error, "REJECTED", "target is already on the channel"},
          else: :ok
    end
  end

  defp remove_membership(user, membership, channel, action, reason, actor) do
    all_memberships = UserChannels.get_by_channel_name(channel.name)

    UserChannels.delete(membership, %{
      "action" => action,
      "channel" => channel.name,
      "join_id" => membership.join_id,
      "by" => actor,
      "reason" => reason || ""
    })

    if Enum.count(all_memberships) == 1 do
      ChannelInvites.delete_by_channel_name(channel.name)
      Channels.delete(channel)
    end

    recipients = all_memberships |> Enum.map(& &1.user_pid) |> Users.get_by_pids()
    command = if action == "kick", do: "KICK", else: "PART"
    params = if command == "KICK", do: [channel.name, user.nick], else: [channel.name]
    trailing = if action == "kick", do: reason || "remote kick", else: reason
    Dispatcher.broadcast(%Message{command: command, params: params, trailing: trailing}, :server, recipients)
    :ok
  end

  defp invite_actor_guard(%{"user" => uid}, %{"inviter_uid" => uid}), do: :ok

  defp invite_actor_guard(%{"service" => service}, %{"inviter_uid" => uid})
       when service in ["NickServ", "ChanServ"] and is_binary(uid),
       do: :ok

  defp invite_actor_guard(_frame, _args), do: {:error, "REJECTED", "inviter does not match actor"}

  defp invite_permission(%{"service" => service}, _args, _channel, runtime, context)
       when service in ["NickServ", "ChanServ"],
       do:
         if(is_binary(runtime.services_authority) and context[:origin_sid] == runtime.services_authority,
           do: :ok,
           else: {:error, "UNAVAILABLE", "service authority is unavailable"}
         )

  defp invite_permission(%{"user" => uid}, _args, channel, runtime, _context) do
    if actor_operator?(%{"user" => uid}, channel, runtime),
      do: :ok,
      else: {:error, "REJECTED", "inviter lacks channel privilege"}
  end

  defp invite_permission(_frame, _args, _channel, _runtime, _context),
    do: {:error, "REJECTED", "inviter is not authorized"}

  defp actor_operator?(%{"user" => uid}, %Channel{name: name}, runtime) do
    key = CaseMapping.normalize(name)

    runtime.memberships[uid]
    |> case do
      %{entries: entries} ->
        case Enum.find(entries, &(&1["channel"] == key)) do
          %{"join_id" => join_id} -> status_enabled?(runtime, key, uid, join_id, "o") or local_operator?(uid, key)
          _ -> false
        end

      _ ->
        local_operator?(uid, key)
    end
  end

  defp actor_operator?(_actor, _channel, _runtime), do: false

  defp local_operator?(uid, channel_key) do
    UserChannels.get_by_uid(uid)
    |> Enum.any?(&(&1.channel_name_key == channel_key and :o in &1.modes))
  end

  defp status_enabled?(runtime, channel_key, uid, join_id, mode) do
    case runtime.channels[channel_key] do
      %{statuses: statuses} ->
        case statuses[{uid, join_id, mode}] do
          %{value: %{enabled: true}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_expiry(0), do: :ok

  defp valid_expiry(expires_ms) when is_integer(expires_ms) do
    if expires_ms > System.system_time(:millisecond), do: :ok, else: {:error, "STALE", "invitation has expired"}
  end

  defp valid_expiry(_expires_ms), do: {:error, "REJECTED", "invalid invitation expiry"}

  defp create_invite(args, target, channel, frame) do
    setter = "ENP/" <> frame["origin"]["sid"]

    ChannelInvites.create(%{
      user_pid: target.pid,
      channel_name_key: channel.name_key,
      invite_id: args["invite_id"],
      expires_ms: args["expires_ms"],
      setter: setter
    })
  end

  defp notify_invite(invite, target, channel, _runtime) do
    Dispatcher.broadcast(%Message{command: "INVITE", params: [target.nick, channel.name]}, :server, target)

    observers =
      UserChannels.get_by_channel_name(channel.name)
      |> Enum.map(& &1.user_pid)
      |> Users.get_by_pids()
      |> Enum.filter(&("invite-notify" in &1.capabilities))

    Dispatcher.broadcast(%Message{command: "INVITE", params: [target.nick, channel.name]}, :server, observers)

    if is_struct(invite, ElixIRCd.Tables.ChannelInvite),
      do: :ok,
      else: {:error, "REJECTED", "invitation was not stored"}
  end

  defp invite_row(args, channel) do
    %{
      "kind" => "invite.notice",
      "invite_id" => args["invite_id"],
      "target_uid" => args["target_uid"],
      "inviter_uid" => args["inviter_uid"],
      "channel" => channel_ref(channel),
      "expires_ms" => args["expires_ms"]
    }
  end

  defp channel_ref(%Channel{} = channel) do
    %{
      "name" => channel.name,
      "born_ms" => max(channel.born_ms || DateTime.to_unix(channel.created_at, :millisecond), 1),
      "cid" => channel.cid
    }
  end

  defp valid_ident?(ident) when is_binary(ident) do
    max_length = Application.fetch_env!(:elixircd, :user)[:max_ident_length]
    byte_size(ident) > 0 and byte_size(ident) <= max_length and Regex.match?(~r/^[a-zA-Z0-9\-_~]+$/, ident)
  end

  defp valid_ident?(_ident), do: false

  defp bound_account(runtime, %{"account_id" => account_id, "auth_epoch" => auth_epoch, "policy_epoch" => policy_epoch}) do
    if Policy.grant_ready?(runtime.policy) do
      with true <- policy_epoch == runtime.policy.epoch,
           {:ok, account} <- Policy.get(runtime.policy, "account", account_id),
           true <- account["auth_epoch"] == auth_epoch do
        {:ok, account}
      else
        false -> {:error, :invalid_binding}
        :not_found -> {:error, :invalid_binding}
      end
    else
      {:error, :policy_unavailable}
    end
  end

  defp bound_account(_runtime, _binding), do: {:error, :invalid_binding}

  defp valid_oper_role(true, "oper"), do: :ok
  defp valid_oper_role(false, nil), do: :ok
  defp valid_oper_role(_enabled, _role), do: {:error, :invalid_oper_role}

  defp publish_account_success(user, account_name) do
    %Message{
      command: :rpl_loggedin,
      params: [user.nick || "*", user_mask(user, :registration), account_name],
      trailing: "You are now logged in as #{account_name}"
    }
    |> Dispatcher.broadcast(:server, user)

    %Message{
      command: :rpl_saslsuccess,
      params: [user.nick || "*"],
      trailing: "SASL authentication successful"
    }
    |> Dispatcher.broadcast(:server, user)

    Nickserv.notify_account_change(user, account_name)
  end

  defp publish_account_logout(user, account_name) do
    %Message{command: "MODE", params: [user.nick || "*", "-r"]}
    |> Dispatcher.broadcast(:server, user)

    %Message{
      command: :rpl_loggedout,
      params: [user.nick || "*", user_mask(user, :registration)],
      trailing: "You are now logged out (was: #{account_name})"
    }
    |> Dispatcher.broadcast(:server, user)

    Nickserv.notify_account_logout(user)
  end

  defp publish_oper_change(user, true) do
    %Message{command: :rpl_youreoper, params: [user.nick || "*"], trailing: "You are now an IRC operator"}
    |> Dispatcher.broadcast(:server, user)

    %Message{command: "MODE", params: [user.nick || "*", "+o"]}
    |> Dispatcher.broadcast(:server, user)

    :ok
  end

  defp publish_oper_change(user, false) do
    %Message{command: "MODE", params: [user.nick || "*", "-o"]}
    |> Dispatcher.broadcast(:server, user)

    :ok
  end

  defp decode_bytes(value) when is_binary(value), do: value

  defp decode_bytes(%{"b64" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} -> decoded
      :error -> nil
    end
  end

  defp decode_bytes(_value), do: nil
end
