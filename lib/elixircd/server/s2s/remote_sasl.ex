defmodule ElixIRCd.Server.S2S.RemoteSASL do
  @moduledoc """
  Bridges a C2S SASL exchange to the configured native S2S authority.

  The connection keeps only the bounded SASL transcript in its local
  `SaslSession`. Credential verification stays at the services authority and
  the returned binding is installed through the existing owner-domain action,
  so account effects and publication retain the normal transaction boundary.
  """

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Domain
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Tables.User

  @plain "PLAIN"
  @ecdsa "ECDSA-NIST256P-CHALLENGE"
  @sasl_context :native_s2s_sasl
  @transient_cancel_key {__MODULE__, :transient_cancel}

  @type remote_state :: %{
          remote_sasl: %{
            authority: String.t(),
            attempt_id: Identity.id(),
            mechanism: String.t(),
            step: non_neg_integer(),
            pending?: boolean()
          }
        }

  @doc "Returns the remote services authority for a local C2S user, if one exists."
  @spec authority(User.t()) :: {:ok, GenServer.server(), map(), String.t()} | {:error, term()}
  def authority(%User{}) do
    with manager when is_pid(manager) <- Process.whereis(Manager),
         {:ok, runtime} <- View.runtime(manager),
         authority when is_binary(authority) <- runtime.services_authority,
         true <- authority != runtime.sid,
         true <- reachable?(runtime, authority) do
      {:ok, manager, runtime, authority}
    else
      nil -> {:error, :services_authority_unavailable}
      false -> {:error, :services_authority_is_local}
      {:error, _reason} = error -> error
      _ -> {:error, :services_authority_unavailable}
    end
  rescue
    _ -> {:error, :services_authority_unavailable}
  catch
    :exit, _reason -> {:error, :services_authority_unavailable}
  end

  def authority(_user), do: {:error, :services_authority_unavailable}

  @doc "Returns whether the user must authenticate through the remote authority."
  @spec remote?(User.t()) :: boolean()
  def remote?(%User{} = user), do: match?({:ok, _manager, _runtime, _authority}, authority(user))
  def remote?(_user), do: false

  @doc "Returns whether a distinct services authority is configured for the local user."
  @spec configured?(User.t()) :: boolean()
  def configured?(%User{}) do
    with manager when is_pid(manager) <- Process.whereis(Manager),
         {:ok, runtime} <- View.runtime(manager),
         authority when is_binary(authority) <- runtime.services_authority,
         true <- authority != runtime.sid do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _reason -> false
  end

  def configured?(_user), do: false

  @doc "Returns the native mechanisms that this C2S bridge can forward."
  @spec mechanisms() :: [String.t()]
  def mechanisms, do: [@plain, @ecdsa]

  @doc "Builds the transient state stored in the local SASL session."
  @spec start_state(User.t(), String.t()) :: {:ok, remote_state()} | {:error, term()}
  def start_state(%User{} = user, mechanism) when mechanism in [@plain, @ecdsa] do
    with {:ok, _manager, _runtime, authority} <- authority(user) do
      {:ok,
       %{
         remote_sasl: %{
           authority: authority,
           attempt_id: Identity.nonce(),
           mechanism: mechanism,
           step: 0,
           pending?: true
         }
       }}
    end
  end

  def start_state(_user, _mechanism), do: {:error, :unsupported_remote_mechanism}

  @doc "Queues the authority-side start request after the local SASL row is created."
  @spec enqueue_start(User.t(), remote_state()) :: :queued | {:error, term()}
  def enqueue_start(%User{} = user, %{remote_sasl: remote} = state) do
    with {:ok, manager, runtime, authority} <- authority(user),
         true <- authority == remote.authority,
         :queued <- queue_request(user, manager, runtime, remote, 0, "start", nil) do
      _ = state
      :queued
    else
      false -> {:error, :stale_services_authority}
      {:error, _reason} = error -> error
    end
  end

  @doc "Queues one client response to the authority and returns its pending state."
  @spec enqueue_step(User.t(), ElixIRCd.Tables.SaslSession.t()) :: {:ok, remote_state()} | {:error, term()}
  def enqueue_step(%User{} = user, %{state: %{remote_sasl: remote}, buffer: data})
      when is_binary(data) and is_map(remote) do
    with {:ok, manager, runtime, authority} <- authority(user),
         true <- authority == remote.authority,
         false <- remote.pending?,
         step <- remote.step + 1,
         :queued <- queue_request(user, manager, runtime, remote, step, "step", data) do
      {:ok, put_in(%{remote_sasl: remote}, [:remote_sasl, :step], step) |> put_in([:remote_sasl, :pending?], true)}
    else
      false -> {:error, :stale_remote_sasl_session}
      {:error, _reason} = error -> error
    end
  end

  def enqueue_step(_user, _session), do: {:error, :invalid_remote_sasl_session}

  @doc "Queues an abort when a client cancels or disconnects during remote SASL."
  @spec abort(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :queued | {:error, term()}
  def abort(%User{} = user, %{state: %{remote_sasl: remote}}) when is_map(remote) do
    with {:ok, manager, runtime, authority} <- authority(user),
         true <- authority == remote.authority,
         :ok <- queue_cancel(user, manager, remote),
         :queued <- queue_request(user, manager, runtime, remote, remote.step, "abort", nil) do
      :queued
    else
      false -> {:error, :stale_services_authority}
      {:error, _reason} = error -> error
    end
  end

  def abort(_user, _session), do: {:error, :invalid_remote_sasl_session}

  @doc "Cancels local SASL state when the authority is no longer reachable."
  @spec cancel_local(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok | {:error, term()}
  def cancel_local(%User{} = user, %{state: %{remote_sasl: remote}}) when is_map(remote) do
    case Process.whereis(Manager) do
      manager when is_pid(manager) -> queue_cancel(user, manager, remote)
      _ -> :ok
    end
  end

  def cancel_local(_user, _session), do: {:error, :invalid_remote_sasl_session}

  @doc "Drains one committed C2S-to-authority SASL request."
  @spec drain_request(map()) :: :ok
  def drain_request(%{kind: :s2s_sasl_request} = intent) do
    case drain(intent) do
      :queued -> :ok
      {:error, _reason} -> :ok
    end
  end

  def drain_request(_intent), do: :ok

  @doc "Drains one committed cancellation without persisting local process identities."
  @spec drain_cancel(map()) :: :ok
  def drain_cancel(%{kind: :s2s_sasl_cancel} = intent) do
    {manager, recipient} = take_transient_cancel(intent)

    case cancel_attempt(intent, manager, recipient) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  def drain_cancel(_intent), do: :ok

  @doc "Handles one correlated authority reply in the C2S connection process."
  @spec handle_reply(pid(), String.t(), map(), map()) :: :handled | :ignored
  def handle_reply(pid, uid, result, %{sasl: @sasl_context} = context)
      when is_pid(pid) and is_binary(uid) and is_map(result) do
    case current_session(pid, uid, context) do
      {:ok, user, session} -> handle_reply_for_session(user, session, result, context)
      _ -> :handled
    end
  rescue
    _ -> :handled
  end

  def handle_reply(_pid, _uid, _result, _context), do: :ignored

  @doc "Builds the authority callback options used by the native manager."
  @spec authority_options() :: keyword()
  def authority_options do
    [
      plain_lookup: &ElixIRCd.Server.S2S.SASLAuthority.plain_lookup/3,
      ecdsa_lookup: &ElixIRCd.Server.S2S.SASLAuthority.ecdsa_lookup/3
    ]
  end

  defp queue_request(user, manager, runtime, remote, step, phase, data) do
    intent = %{
      kind: :s2s_sasl_request,
      sensitive: true,
      manager: manager,
      target_sid: remote.authority,
      actor: %{"server" => runtime.sid},
      uid: user.uid,
      recipient: user.pid,
      args: %{
        "uid" => user.uid,
        "attempt_id" => remote.attempt_id,
        "step" => step,
        "phase" => phase,
        "mechanism" => remote.mechanism,
        "data" => if(phase == "step", do: data, else: nil),
        "client_info" => client_info(user)
      },
      response_context: %{
        sasl: @sasl_context,
        attempt_id: remote.attempt_id,
        step: step,
        phase: phase,
        mechanism: remote.mechanism,
        authority_sid: remote.authority
      }
    }

    case Output.collect_intent(intent) do
      :ok -> :queued
      :inactive -> drain(intent)
      {:error, _reason} = error -> error
    end
  end

  defp queue_cancel(user, manager, remote) do
    cancel_token = Identity.nonce()

    intent = %{
      kind: :s2s_sasl_cancel,
      uid: user.uid,
      connection_generation: connection_generation(user),
      cancel_token: cancel_token,
      attempt_id: remote.attempt_id
    }

    remember_transient_cancel(cancel_token, manager, user.pid)

    case Output.collect_intent(intent) do
      :ok ->
        :ok

      :inactive ->
        release_transient_cancel(cancel_token)
        cancel_attempt(intent, manager, user.pid)

      {:error, _reason} = error ->
        release_transient_cancel(cancel_token)
        error
    end
  end

  defp cancel_attempt(
         %{uid: uid, connection_generation: generation, attempt_id: attempt_id},
         manager_override,
         recipient_override
       )
       when is_binary(uid) and is_binary(generation) and is_binary(attempt_id) do
    manager = manager_override || Process.whereis(Manager)

    with true <- is_pid(manager) or is_atom(manager),
         {:ok, recipient} <- recipient_for_cancel(uid, generation, recipient_override) do
      _ = Manager.cancel_sasl_attempt(manager, recipient, uid, attempt_id)
      :ok
    else
      false -> {:error, :manager_unavailable}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp cancel_attempt(_intent, _manager, _recipient), do: {:error, :invalid_sasl_cancel}

  defp recipient_for_cancel(_uid, _generation, recipient) when is_pid(recipient), do: {:ok, recipient}

  defp recipient_for_cancel(uid, generation, nil) do
    read = fn -> Users.get_by_uid(uid) end

    with {:ok, result} <- Memento.transaction(read),
         {:ok, %User{pid: pid, connection_generation: ^generation}} <- result,
         true <- is_pid(pid) do
      {:ok, pid}
    else
      _ -> {:error, :recipient_unavailable}
    end
  rescue
    _ -> {:error, :recipient_unavailable}
  catch
    :exit, _reason -> {:error, :recipient_unavailable}
  end

  defp reachable?(runtime, sid) do
    match?(%MapSet{}, runtime.reachable_sids) and MapSet.member?(runtime.reachable_sids, sid)
  end

  defp drain(%{
         manager: manager,
         target_sid: target_sid,
         actor: actor,
         args: args,
         recipient: recipient,
         uid: uid,
         response_context: context
       }) do
    case Manager.request_with_reply_context(
           manager,
           target_sid,
           actor,
           "sasl",
           args,
           empty_guards(),
           recipient,
           uid,
           context
         ) do
      {:ok, _request_id} ->
        :queued

      {:error, reason} ->
        send_unavailable(recipient, uid, context, reason)
        {:error, reason}
    end
  catch
    :exit, reason ->
      send_unavailable(recipient, uid, context, reason)
      {:error, reason}
  end

  defp send_unavailable(recipient, uid, context, reason) when is_pid(recipient) do
    if Process.alive?(recipient) do
      send(recipient, {
        :s2s_reply,
        uid,
        Identity.nonce(),
        %{
          status: "UNAVAILABLE",
          payload: ElixIRCd.Server.S2S.Requests.error_payload("UNAVAILABLE", safe_reason(reason)),
          done: true
        },
        context
      })
    end

    :ok
  end

  defp send_unavailable(_recipient, _uid, _context, _reason), do: :ok

  defp current_session(pid, uid, context) do
    Memento.transaction!(fn ->
      with {:ok, %User{pid: ^pid} = user} <- Users.get_by_uid(uid),
           {:ok, session} <- SaslSessions.get(pid),
           true <- valid_context?(session, context) do
        {:ok, user, session}
      else
        _ -> {:error, :stale_remote_sasl_reply}
      end
    end)
  end

  defp valid_context?(%{state: %{remote_sasl: remote}}, context) when is_map(remote) do
    remote.attempt_id == context[:attempt_id] and
      remote.mechanism == context[:mechanism] and
      remote.step == context[:step] and remote.pending? == true
  end

  defp valid_context?(_session, _context), do: false

  defp handle_reply_for_session(
         user,
         session,
         %{status: "OK", payload: %{"sasl" => "continue", "data" => data}},
         context
       ) do
    continue_session(user, session, context, data)
  end

  defp handle_reply_for_session(
         user,
         _session,
         %{status: "OK", payload: %{"sasl" => "success", "binding" => binding}},
         context
       )
       when is_map(binding) do
    case install_binding(user, binding, context) do
      :ok -> delete_session(user.pid)
      {:error, reason} -> fail_session(user, "SASL authentication failed: #{safe_reason(reason)}")
    end

    :handled
  end

  defp handle_reply_for_session(
         user,
         _session,
         %{status: "OK", payload: %{"sasl" => "failure", "code" => code}},
         _context
       ) do
    fail_session(user, "SASL authentication failed: #{safe_reason(code)}")
    :handled
  end

  defp handle_reply_for_session(user, _session, %{status: "OK", payload: %{"sasl" => "aborted"}}, _context) do
    fail_session(user, "SASL authentication aborted")
    :handled
  end

  defp handle_reply_for_session(user, _session, %{status: status}, _context) when is_binary(status) do
    fail_session(user, "SASL authentication failed: #{status}")
    :handled
  end

  defp handle_reply_for_session(_user, _session, _result, _context), do: :handled

  defp continue_session(user, session, context, data) do
    Output.transaction(
      fn ->
        with {:ok, current} <- SaslSessions.get(user.pid),
             true <- valid_context?(current, context),
             next_state <- put_in(current.state, [:remote_sasl, :pending?], false),
             SaslSessions.update(current, %{buffer: "", state: next_state}),
             message <- authenticate_message(data) do
          Dispatcher.broadcast(message, :server, user)
        else
          _ -> :ok
        end
      end,
      drain_fun: &Dispatcher.drain_intent/1
    )

    _ = session
    :handled
  end

  defp authenticate_message(data) when is_binary(data) and data != "",
    do: %Message{command: "AUTHENTICATE", params: [data]}

  defp authenticate_message(_data), do: %Message{command: "AUTHENTICATE", params: ["+"]}

  defp install_binding(%User{} = user, binding, context) do
    with manager when is_pid(manager) <- Process.whereis(Manager),
         {:ok, runtime} <- View.runtime(manager),
         true <- runtime.services_authority == context[:authority_sid],
         runtime <- ensure_local_user_projection(runtime, user),
         frame <- account_frame(user, binding, runtime),
         domain_context <- %{
           local_sid: runtime.sid,
           services_authority: runtime.services_authority,
           origin_sid: context[:authority_sid],
           origin_boot: get_in(runtime.nodes, [context[:authority_sid], "boot"])
         },
         result <- Domain.execute_deferred(frame, runtime, domain_context),
         :ok <- drain_domain_result(result) do
      :ok
    else
      false -> {:error, :stale_services_authority}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :account_binding_rejected}
    end
  rescue
    _ -> {:error, :account_binding_rejected}
  catch
    :exit, reason -> {:error, reason}
  end

  defp drain_domain_result({:ok, _payload, nil}), do: :ok

  defp drain_domain_result({:ok, _payload, group}) when is_map(group) do
    case Output.drain_pending(group, &Dispatcher.drain_intent/1) do
      :ok -> :ok
      {:error, reason} -> {:error, {:effect_drain_failed, reason}}
    end
  end

  defp drain_domain_result({:error, _status, message, nil}), do: {:error, message}

  defp drain_domain_result({:error, _status, message, group}) when is_map(group) do
    case Output.drain_pending(group, &Dispatcher.drain_intent/1) do
      :ok -> {:error, message}
      {:error, reason} -> {:error, {:effect_drain_failed, reason}}
    end
  end

  defp account_frame(user, binding, runtime) do
    %{
      "method" => "user_action",
      "actor" => %{"service" => "NickServ"},
      "args" => %{
        "action" => "account",
        "target_uid" => user.uid,
        "value" => %{"binding" => binding},
        "reason" => "SASL PLAIN"
      },
      "guards" => %{
        "actor_uid" => nil,
        "actor_user_rev" => nil,
        "actor_join_id" => nil,
        "target_user_rev" => user.owner_rev || 1,
        "target_join_id" => nil,
        "channel" => nil,
        "policy_epoch" => runtime.policy.epoch,
        "policy_revision" => runtime.policy.revision
      }
    }
  end

  defp ensure_local_user_projection(runtime, %User{uid: uid, home_sid: home_sid, home_boot: home_boot}) do
    if Map.has_key?(runtime.users, uid) do
      runtime
    else
      home = %{"sid" => home_sid || runtime.sid, "boot" => home_boot || runtime.boot}
      %{runtime | users: Map.put(runtime.users, uid, %{"home" => home})}
    end
  end

  defp delete_session(pid) do
    Output.transaction(fn -> SaslSessions.delete(pid) end, drain_fun: &Dispatcher.drain_intent/1)
    :ok
  end

  defp fail_session(%User{} = user, reason) do
    Output.transaction(
      fn ->
        Dispatcher.broadcast(
          %Message{command: :err_saslfail, params: [user_reply(user)], trailing: reason},
          :server,
          user
        )

        SaslSessions.delete(user.pid)
      end,
      drain_fun: &Dispatcher.drain_intent/1
    )

    :ok
  end

  defp client_info(%User{} = user) do
    %{
      "secure_client" => user.transport in [:tls, :wss],
      "realhost" => user.hostname || "",
      "address" => address(user.ip_address),
      "client_certfp" => nil
    }
  end

  defp address(address) do
    address |> :inet.ntoa() |> to_string()
  rescue
    _ -> ""
  end

  defp empty_guards do
    %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }
  end

  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 512)
  defp safe_reason(reason), do: reason |> inspect() |> String.slice(0, 512)

  defp connection_generation(%User{connection_generation: generation}) when is_binary(generation), do: generation
  defp connection_generation(%User{uid: uid}) when is_binary(uid), do: uid

  defp remember_transient_cancel(token, manager, recipient)
       when is_binary(token) and (is_pid(manager) or is_atom(manager)) and is_pid(recipient) do
    Process.put({@transient_cancel_key, token}, {manager, recipient})
  end

  defp release_transient_cancel(token) when is_binary(token),
    do: Process.delete({@transient_cancel_key, token})

  defp take_transient_cancel(%{cancel_token: token}) when is_binary(token) do
    value = Process.get({@transient_cancel_key, token}, {nil, nil})
    Process.delete({@transient_cancel_key, token})
    value
  end

  defp take_transient_cancel(_intent), do: {nil, nil}
end
