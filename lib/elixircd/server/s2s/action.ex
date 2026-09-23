defmodule ElixIRCd.Server.S2S.Action do
  @moduledoc """
  Builds guarded owner requests for C2S actions whose target is remote.

  This module only reads the immutable network projection and queues a bounded
  request. The owner-side mutation remains in `S2S.Domain`.
  """

  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @transient_recipient_key {__MODULE__, :transient_recipient}

  @doc "Resolves a nickname only when its current owner is another server."
  @spec remote_target(map(), String.t()) ::
          {:ok, String.t(), User.t(), String.t()} | :local | {:error, :not_found | :unavailable}
  def remote_target(runtime, nickname) when is_map(runtime) and is_binary(nickname) do
    case View.user_by_nick(runtime, nickname) do
      {:ok, uid, %User{home_sid: home_sid} = user} when is_binary(home_sid) and home_sid != runtime.sid ->
        {:ok, uid, user, home_sid}

      {:ok, _uid, _user} ->
        :local

      {:error, :user_not_found} ->
        {:error, :not_found}

      _ ->
        {:error, :unavailable}
    end
  end

  def remote_target(_runtime, _nickname), do: {:error, :unavailable}

  @doc "Returns the current channel incarnation and both guarded memberships."
  @spec channel_context(map(), String.t(), User.t(), String.t(), User.t()) ::
          {:ok, map(), UserChannel.t(), UserChannel.t()} | {:error, term()}
  def channel_context(runtime, channel_name, actor, target_uid, target_user)
      when is_map(runtime) and is_binary(channel_name) and is_binary(target_uid) do
    with {:ok, _channel, channel} <- View.channel(runtime, channel_name),
         {:ok, actor_membership} <- View.membership(runtime, actor.uid, channel_name),
         {:ok, target_membership} <- View.membership(runtime, target_uid, channel_name),
         true <- target_user.uid == target_uid do
      {:ok, channel, actor_membership, target_membership}
    else
      false -> {:error, :target_not_found}
      {:error, :channel_not_found} -> {:error, :channel_not_found}
      {:error, :membership_not_found} -> {:error, :membership_not_found}
    end
  end

  @doc "Returns the current channel incarnation and the actor membership."
  @spec actor_channel_context(map(), String.t(), User.t()) ::
          {:ok, map(), UserChannel.t()} | {:error, term()}
  def actor_channel_context(runtime, channel_name, actor)
      when is_map(runtime) and is_binary(channel_name) do
    with {:ok, channel_struct, channel} <- View.channel(runtime, channel_name),
         {:ok, actor_membership} <- View.membership(runtime, actor.uid, channel_name) do
      context = %{ref: channel.ref, name: channel_struct.name, modes: channel_struct.modes}
      {:ok, context, actor_membership}
    else
      {:error, :channel_not_found} -> {:error, :channel_not_found}
      {:error, :membership_not_found} -> {:error, :membership_not_found}
    end
  end

  @doc "Builds the closed guard object required by user_action and invite."
  @spec guards(map(), User.t(), UserChannel.t(), User.t(), UserChannel.t(), map()) :: map()
  def guards(runtime, actor, actor_membership, target, target_membership, channel) do
    %{
      "actor_uid" => actor.uid,
      "actor_user_rev" => actor.owner_rev,
      "actor_join_id" => actor_membership.join_id,
      "target_user_rev" => target.owner_rev,
      "target_join_id" => target_membership.join_id,
      "channel" => channel.ref,
      "policy_epoch" => runtime.policy.epoch,
      "policy_revision" => runtime.policy.revision
    }
  end

  @doc "Builds guards for an invitation whose target has no membership yet."
  @spec invite_guards(map(), User.t(), UserChannel.t(), User.t(), map()) :: map()
  def invite_guards(runtime, actor, actor_membership, target, channel) do
    %{
      "actor_uid" => actor.uid,
      "actor_user_rev" => actor.owner_rev,
      "actor_join_id" => actor_membership.join_id,
      "target_user_rev" => target.owner_rev,
      "target_join_id" => nil,
      "channel" => channel.ref,
      "policy_epoch" => runtime.policy.epoch,
      "policy_revision" => runtime.policy.revision
    }
  end

  @doc "Queues a remote owner request and returns a command-friendly result."
  @spec enqueue(GenServer.server(), String.t(), User.t(), String.t(), map(), map(), map()) ::
          :queued | {:error, term()}
  def enqueue(manager, target_sid, actor, method, args, guards, response_context \\ %{})
      when is_binary(target_sid) and is_map(args) and is_map(guards) and is_map(response_context) do
    recipient_token = Identity.nonce()

    intent = %{
      kind: :s2s_request,
      target_sid: target_sid,
      actor: %{"user" => actor.uid},
      method: method,
      args: args,
      guards: guards,
      uid: actor.uid,
      connection_generation: connection_generation(actor),
      recipient_token: recipient_token,
      response_context: response_context
    }

    remember_transient_recipient(recipient_token)

    case Output.collect_intent(intent) do
      :ok ->
        :queued

      :inactive ->
        forget_transient_recipient(recipient_token)
        originate(intent, manager, self())

      {:error, _reason} = error ->
        forget_transient_recipient(recipient_token)
        error
    end
  end

  @doc "Queues a short owner-action sequence whose later guards follow the prior owner revision."
  @spec enqueue_sequence(GenServer.server(), String.t(), User.t(), [map()], map()) ::
          :queued | {:error, term()}
  def enqueue_sequence(manager, target_sid, actor, requests, response_context \\ %{})
      when is_binary(target_sid) and is_list(requests) and requests != [] and is_map(response_context) do
    recipient_token = Identity.nonce()

    intent = %{
      kind: :s2s_request_sequence,
      target_sid: target_sid,
      actor: %{"user" => actor.uid},
      requests: requests,
      uid: actor.uid,
      connection_generation: connection_generation(actor),
      recipient_token: recipient_token,
      response_context: response_context
    }

    remember_transient_recipient(recipient_token)

    case Output.collect_intent(intent) do
      :ok ->
        :queued

      :inactive ->
        forget_transient_recipient(recipient_token)
        start_sequence(intent, manager, self())

      {:error, _reason} = error ->
        forget_transient_recipient(recipient_token)
        error
    end
  end

  @doc "Originates a committed remote request and reports post-commit failures to its client."
  @spec drain_request(map()) :: :ok
  def drain_request(%{kind: :s2s_request} = intent) do
    recipient = take_transient_recipient(intent)

    case originate(intent, nil, recipient) do
      :queued ->
        :ok

      {:error, reason} ->
        notify_unavailable(intent, reason, recipient)
    end
  end

  @doc "Starts a committed sequence without holding the originating C2S transaction."
  @spec drain_request_sequence(map()) :: :ok
  def drain_request_sequence(%{kind: :s2s_request_sequence} = intent) do
    recipient = take_transient_recipient(intent)
    _ = spawn(fn -> run_sequence(intent, nil, recipient) end)
    :ok
  end

  @doc "Builds the response metadata allowed for a labeled C2S request."
  @spec response_context(User.t(), map(), String.t() | nil) :: map()
  def response_context(%User{capabilities: capabilities}, tags, error_notice \\ nil)
      when is_map(tags) do
    label = Map.get(tags, "label")

    label =
      if "batch" in capabilities and "labeled-response" in capabilities and is_binary(label) and
           byte_size(label) in 1..64,
         do: label,
         else: nil

    context = if is_binary(label), do: %{label: label}, else: %{}
    if is_binary(error_notice), do: Map.put(context, :error_notice, error_notice), else: context
  end

  @doc "Adds one locally-rendered success item to a correlated owner response."
  @spec success_context(map(), map()) :: map()
  def success_context(context, item) when is_map(context) and is_map(item) do
    Map.put(context, :success_item, item)
  end

  defp originate(intent, manager_override, recipient_override)

  defp originate(
         %{
           target_sid: target_sid,
           actor: actor,
           method: method,
           args: args,
           guards: guards,
           uid: uid,
           connection_generation: generation,
           response_context: response_context
         },
         manager_override,
         recipient_override
       ) do
    manager = manager_override || Process.whereis(Manager)

    with true <- is_pid(manager) or is_atom(manager),
         {:ok, recipient} <- current_recipient(uid, generation, recipient_override) do
      case Manager.request_with_reply_context(
             manager,
             target_sid,
             actor,
             method,
             args,
             guards,
             recipient,
             uid,
             response_context
           ) do
        {:ok, _request_id} -> :queued
        {:error, _reason} = error -> error
      end
    else
      false -> {:error, :manager_unavailable}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp start_sequence(intent, manager, recipient) do
    _ = spawn(fn -> run_sequence(intent, manager, recipient) end)
    :queued
  end

  defp run_sequence(intent, manager_override, recipient_override) do
    manager = manager_override || Process.whereis(Manager)

    with true <- is_pid(manager) or is_atom(manager),
         {:ok, recipient} <- current_recipient(intent.uid, intent.connection_generation, recipient_override) do
      monitor = Process.monitor(recipient)

      try do
        run_sequence_step(intent, intent.requests, monitor, manager, recipient)
      after
        Process.demonitor(monitor, [:flush])
      end
    else
      false -> notify_unavailable(intent, :manager_unavailable)
      {:error, _reason} = error -> notify_unavailable(intent, error)
    end
  end

  defp run_sequence_step(_intent, [], _monitor, _manager, _recipient), do: :ok

  defp run_sequence_step(intent, [request | remaining], monitor, manager, recipient) do
    case originate_sequence_request(intent, request, self(), manager) do
      {:ok, request_id} ->
        receive do
          {:s2s_reply, uid, ^request_id, result, _context} when uid == intent.uid ->
            handle_sequence_reply(intent, remaining, request_id, result, monitor, manager, recipient)

          {:DOWN, ^monitor, :process, _pid, _reason} ->
            Manager.cancel_recipient(manager, self(), intent.uid)
            :ok
        after
          sequence_timeout(manager) ->
            Manager.cancel_recipient(manager, self(), intent.uid)
            notify_unavailable(intent, :request_timeout)
        end

      {:error, reason} ->
        notify_unavailable(intent, reason)
    end
  end

  defp handle_sequence_reply(intent, remaining, request_id, result, monitor, manager, recipient) do
    cond do
      result[:done] != true ->
        await_sequence_reply(intent, remaining, request_id, monitor, manager, recipient)

      result[:status] != "OK" or remaining == [] ->
        forward_reply(intent, recipient, request_id, result)

      true ->
        case next_sequence_request(remaining, result) do
          {:ok, next_request, rest} -> run_sequence_step(intent, [next_request | rest], monitor, manager, recipient)
          {:error, reason} -> notify_unavailable(intent, reason)
        end
    end
  end

  defp await_sequence_reply(intent, remaining, request_id, monitor, manager, recipient) do
    receive do
      {:s2s_reply, uid, ^request_id, result, _context} when uid == intent.uid ->
        handle_sequence_reply(intent, remaining, request_id, result, monitor, manager, recipient)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        Manager.cancel_recipient(manager, self(), intent.uid)
        :ok
    after
      sequence_timeout(manager) ->
        Manager.cancel_recipient(manager, self(), intent.uid)
        notify_unavailable(intent, :request_timeout)
    end
  end

  defp next_sequence_request([request | rest], result) do
    owner_rev = get_in(result, [:payload, "result", "owner_rev"])

    if is_integer(owner_rev) and owner_rev > 0 do
      {:ok, %{request | guards: Map.put(request.guards, "target_user_rev", owner_rev)}, rest}
    else
      {:error, :missing_owner_revision}
    end
  end

  defp forward_reply(%{uid: uid, response_context: context}, recipient, request_id, result)
       when is_pid(recipient) and is_binary(uid) and is_binary(request_id) and is_map(result) do
    if Process.alive?(recipient), do: send(recipient, {:s2s_reply, uid, request_id, result, context})
    :ok
  end

  defp originate_sequence_request(intent, request, recipient, manager) do
    Manager.request_with_reply_context(
      manager,
      intent.target_sid,
      intent.actor,
      request.method,
      request.args,
      request.guards,
      recipient,
      intent.uid,
      %{}
    )
  catch
    :exit, reason -> {:error, reason}
  end

  defp sequence_timeout(_manager) do
    s2s = Application.get_env(:elixircd, :s2s, [])
    timeouts = if is_list(s2s), do: Keyword.get(s2s, :timeouts, []), else: Map.get(s2s, :timeouts, %{})

    request_ms =
      if is_list(timeouts), do: Keyword.get(timeouts, :request_ms, 15_000), else: Map.get(timeouts, :request_ms, 15_000)

    max(request_ms, 1)
  end

  defp notify_unavailable(intent, reason, recipient_override \\ nil)

  defp notify_unavailable(
         %{uid: uid, connection_generation: generation, response_context: context},
         _reason,
         recipient_override
       )
       when is_binary(uid) and is_binary(generation) and is_map(context) do
    with {:ok, %User{connection_generation: ^generation} = actor} <- current_user(uid),
         recipient <- recipient_override || actor.pid,
         true <- is_pid(recipient),
         true <- Process.alive?(recipient) do
      message = Map.get(context, :error_notice, "Remote action is unavailable")
      tags = if is_binary(context[:label]), do: %{"label" => context[:label]}, else: %{}

      %Message{command: "NOTICE", params: [actor.nick || "*"], trailing: message, tags: tags}
      |> Dispatcher.broadcast(:server, %{actor | pid: recipient})
    end

    :ok
  end

  defp notify_unavailable(_intent, _reason, _recipient_override), do: :ok

  @doc "Returns a wire-safe reason for an owner action."
  @spec reason(String.t() | nil) :: String.t()
  def reason(value) when is_binary(value), do: value
  def reason(_value), do: ""

  defp current_recipient(_uid, _generation, recipient) when is_pid(recipient), do: {:ok, recipient}

  defp current_recipient(uid, generation, nil) do
    with {:ok, %User{connection_generation: ^generation} = user} <- current_user(uid),
         pid when is_pid(pid) <- user.pid do
      {:ok, pid}
    else
      _ -> {:error, :recipient_unavailable}
    end
  end

  defp current_user(uid) when is_binary(uid) do
    read = fn -> Users.get_by_uid(uid) end

    if Memento.Transaction.inside?() do
      read.()
    else
      case Memento.transaction(read) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :user_not_found}
      end
    end
  rescue
    _ -> {:error, :user_not_found}
  catch
    :exit, _reason -> {:error, :user_not_found}
  end

  defp current_user(_uid), do: {:error, :user_not_found}

  defp remember_transient_recipient(token) when is_binary(token),
    do: Process.put({@transient_recipient_key, token}, self())

  defp forget_transient_recipient(token) when is_binary(token),
    do: Process.delete({@transient_recipient_key, token})

  defp take_transient_recipient(%{recipient_token: token}) when is_binary(token) do
    recipient = Process.get({@transient_recipient_key, token})
    Process.delete({@transient_recipient_key, token})
    recipient
  end

  defp take_transient_recipient(_intent), do: nil

  defp connection_generation(%User{connection_generation: generation}) when is_binary(generation), do: generation
  defp connection_generation(%User{uid: uid}) when is_binary(uid), do: uid
end
