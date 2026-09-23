defmodule ElixIRCd.Server.Dispatcher do
  @moduledoc """
  Module for dispatching messages to users.
  """

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.JobQueue
  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Server.S2S.Action
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.RemoteSASL
  alias ElixIRCd.Service
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User

  @s2s_sink_key {__MODULE__, :s2s_sink}
  @transient_recipient_key {__MODULE__, :transient_recipient}

  @type target :: pid() | User.t()
  @type context :: :server | :chanserv | :nickserv | User.t() | nil
  @type message :: Message.t() | StandardReply.t()

  @doc """
  Broadcasts messages with context to the given targets.

  Standard replies are converted to messages before preparation. This function does not require `standard-replies`, so
  extension-mandated replies can use it.
  """
  @spec broadcast(message() | [message()], context(), target() | [target()]) :: :ok
  def broadcast(messages, context, targets) do
    messages = List.wrap(messages)
    targets = List.wrap(targets)
    source_user = source_user_from_context(context)

    if messages == [] or targets == [] do
      :ok
    else
      any_message_tags? = Enum.any?(targets, &message_tags_capable?/1)

      Enum.each(messages, &broadcast_message(&1, context, targets, source_user, any_message_tags?))
    end
  end

  defp broadcast_message(message, context, targets, source_user, any_message_tags?) do
    record_history? = match?(%User{}, context) and History.enabled?() and History.recordable?(message)
    prepared = prepare_message(message, context, any_message_tags? or record_history?)
    prepared = if record_history?, do: maybe_put_history_time(prepared), else: prepared
    if record_history?, do: History.record(prepared, context)
    Enum.each(targets, &broadcast_to_target(prepared, &1, source_user))
  end

  @doc "Returns the configured IRC server source name."
  @spec server_prefix() :: String.t()
  def server_prefix, do: Application.fetch_env!(:elixircd, :server)[:hostname]

  @doc """
  Sends an optional standard reply when the user negotiated `standard-replies`, or the supplied legacy fallback
  otherwise. Uses the same context and delivery path for both replies. REHASH updates the user's negotiated capabilities
  when support is withdrawn. Extension-mandated replies use `broadcast/3` instead.
  """
  @spec broadcast_standard_reply(StandardReply.t(), context(), User.t(), Message.t()) :: :ok
  def broadcast_standard_reply(%StandardReply{} = reply, context, %User{} = user, %Message{} = fallback) do
    message = if "standard-replies" in user.capabilities, do: reply, else: fallback
    broadcast(message, context, user)
  end

  @doc """
  Sends an already-prepared message without consulting the active response
  context again.
  """
  @spec send_prepared_message(Message.t(), User.t()) :: :ok
  def send_prepared_message(%Message{} = message, %User{pid: nil} = user) do
    case Process.get(@s2s_sink_key) do
      sink when is_function(sink, 1) ->
        sink.(filter_tags(message, user))

      _ ->
        :ok
    end
  end

  def send_prepared_message(%Message{} = message, %User{pid: pid} = user) do
    message = filter_tags(message, user)

    recipient = %{
      uid: user.uid,
      connection_generation: connection_generation(user),
      capability_revision: user.cap_version
    }

    message_context = message_context(message)

    case Output.collect_intent(%{kind: :c2s_message, message: message_context, recipient: recipient}) do
      :inactive -> send_message(message, pid)
      :ok -> :ok
      {:error, _reason} = error -> raise ArgumentError, "output intent rejected: #{inspect(error)}"
    end
  end

  @doc "Queues an already prepared message in the active response batch."
  @spec enqueue_prepared_message(Message.t(), User.t()) :: :ok
  def enqueue_prepared_message(%Message{} = message, %User{} = user) do
    if "batch" in user.capabilities and ResponseContext.buffer(message, user) == :buffered do
      :ok
    else
      send_prepared_message(message, user)
    end
  end

  @doc """
  Enqueues a disconnect after any buffered response for this user. Sending both
  from the command process preserves their order in the connection mailbox.
  """
  @spec disconnect(User.t(), String.t(), keyword()) :: :ok
  def disconnect(%User{pid: pid} = user, reason, options \\ []) when is_list(options) do
    ResponseContext.flush(user)

    recipient_token = transient_recipient_token(pid)

    intent = %{
      kind: :c2s_disconnect,
      uid: user.uid,
      connection_generation: connection_generation(user),
      recipient_token: recipient_token,
      reason: reason
    }

    intent = if Keyword.get(options, :allow_missing, false), do: Map.put(intent, :allow_missing, true), else: intent

    case Output.collect_intent(intent) do
      :inactive ->
        release_transient_recipient(recipient_token)
        send(pid, {:disconnect, reason})

      :ok ->
        :ok

      {:error, _reason} = error ->
        release_transient_recipient(recipient_token)
        raise ArgumentError, "disconnect intent rejected: #{inspect(error)}"
    end

    :ok
  end

  @doc "Drains one committed C2S effect after its transaction has succeeded."
  @spec drain_intent(map()) :: :ok | {:error, term()}
  def drain_intent(%{
        kind: :c2s_message,
        message: message_context,
        recipient: %{uid: uid, connection_generation: generation, capability_revision: capability_revision}
      })
      when is_binary(uid) and is_binary(generation) and is_integer(capability_revision) do
    with {:ok, message} <- message_from_context(message_context),
         {:ok, %User{pid: pid, connection_generation: ^generation, cap_version: ^capability_revision}} <-
           current_user(uid),
         true <- is_pid(pid) do
      send_message(message, pid)
    else
      _ -> :ok
    end
  end

  def drain_intent(%{kind: :c2s_disconnect, allow_missing: true} = intent)
      when is_binary(intent.uid) and is_binary(intent.connection_generation) do
    %{uid: uid, connection_generation: generation, reason: reason} = intent
    recipient = take_transient_recipient(intent)

    with {:ok, pid} <- disconnect_recipient(recipient, uid, generation),
         true <- is_pid(pid),
         true <- Process.alive?(pid) do
      send(pid, {:disconnect, uid, reason})
    end

    :ok
  end

  def drain_intent(%{kind: :c2s_disconnect, uid: uid, connection_generation: generation, reason: reason} = intent)
      when is_binary(uid) and is_binary(generation) do
    recipient = take_transient_recipient(intent)

    with {:ok, pid} <- disconnect_recipient(recipient, uid, generation),
         true <- is_pid(pid),
         true <- current_connection?(pid, uid, generation) do
      send(pid, {:disconnect, reason})
    end

    :ok
  end

  def drain_intent(%{kind: :connection_cleanup, uid: uid, connection_generation: generation} = intent)
      when is_binary(uid) and is_binary(generation) do
    recipient = take_transient_recipient(intent)

    with {:ok, pid} <- cleanup_recipient(recipient, uid, generation), true <- is_pid(pid) do
      NickEnforcement.cancel(pid)

      case Process.whereis(Manager) do
        manager when is_pid(manager) -> Manager.cancel_recipient(manager, pid, uid)
        _ -> :ok
      end
    end

    :ok
  end

  def drain_intent(
        %{kind: :s2s_sasl_cancel, uid: uid, connection_generation: generation, attempt_id: attempt_id} = intent
      )
      when is_binary(uid) and is_binary(generation) and is_binary(attempt_id) do
    _ = RemoteSASL.drain_cancel(intent)

    :ok
  end

  def drain_intent(%{kind: :job_enqueue, module: module, payload: payload, opts: opts})
      when is_atom(module) and is_map(payload) and is_list(opts) do
    _ = JobQueue.enqueue_committed(module, payload, opts)
    :ok
  end

  def drain_intent(%{kind: kind} = intent)
      when kind in [
             :s2s_request,
             :s2s_request_sequence,
             :s2s_sasl_request,
             :s2s_user_put,
             :s2s_user_quit,
             :s2s_memberships,
             :s2s_channel,
             :s2s_channel_list,
             :s2s_member_status,
             :s2s_policy_changed
           ] do
    cond do
      kind == :s2s_request -> Action.drain_request(intent)
      kind == :s2s_request_sequence -> Action.drain_request_sequence(intent)
      kind == :s2s_sasl_request -> RemoteSASL.drain_request(intent)
      true -> Output.drain_publication(intent)
    end
  end

  def drain_intent(_intent), do: :ok

  defp message_context(%Message{} = message) do
    %{
      tags: message.tags,
      prefix: message.prefix,
      command: message.command,
      params: message.params,
      trailing: message.trailing
    }
  end

  defp message_from_context(%{tags: tags, prefix: prefix, command: command, params: params, trailing: trailing})
       when is_map(tags) and (is_binary(command) or is_atom(command)) and is_list(params) and
              (is_binary(prefix) or is_nil(prefix)) and (is_binary(trailing) or is_nil(trailing)) do
    {:ok, %Message{tags: tags, prefix: prefix, command: command, params: params, trailing: trailing}}
  end

  defp message_from_context(_message), do: {:error, :invalid_message_context}

  defp current_user(uid) when is_binary(uid) do
    read_current_user = fn -> Users.get_by_uid(uid) end

    if Memento.Transaction.inside?() do
      read_current_user.()
    else
      case Memento.transaction(read_current_user) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :user_not_found}
      end
    end
  rescue
    _ -> {:error, :user_not_found}
  catch
    :exit, _reason -> {:error, :user_not_found}
  end

  defp current_connection?(pid, uid, generation)
       when is_pid(pid) and is_binary(uid) and is_binary(generation) do
    match?({:ok, %User{pid: ^pid, connection_generation: ^generation}}, current_user(uid))
  end

  defp current_connection?(_pid, _uid, _generation), do: false

  defp connection_generation(%User{connection_generation: generation})
       when is_binary(generation),
       do: generation

  defp connection_generation(%User{uid: uid}) when is_binary(uid), do: uid

  defp disconnect_recipient(pid, _uid, _generation) when is_pid(pid), do: {:ok, pid}

  defp disconnect_recipient(_pid, uid, generation) do
    with {:ok, %User{pid: pid, connection_generation: ^generation}} <- current_user(uid),
         true <- is_pid(pid) do
      {:ok, pid}
    else
      _ -> {:error, :recipient_unavailable}
    end
  end

  defp cleanup_recipient(pid, _uid, _generation) when is_pid(pid), do: {:ok, pid}

  defp cleanup_recipient(_pid, uid, generation) do
    with {:ok, %User{pid: pid, connection_generation: ^generation}} <- current_user(uid),
         true <- is_pid(pid) do
      {:ok, pid}
    else
      _ -> {:error, :recipient_unavailable}
    end
  end

  @doc false
  @spec transient_recipient_token(pid()) :: String.t()
  def transient_recipient_token(pid) when is_pid(pid) do
    token = Identity.nonce()
    Process.put({@transient_recipient_key, token}, pid)
    token
  end

  @doc false
  @spec release_transient_recipient(String.t()) :: pid() | nil
  def release_transient_recipient(token) when is_binary(token),
    do: Process.delete({@transient_recipient_key, token})

  defp take_transient_recipient(%{recipient_token: token}) when is_binary(token) do
    recipient = Process.get({@transient_recipient_key, token})
    Process.delete({@transient_recipient_key, token})
    recipient
  end

  defp take_transient_recipient(_intent), do: nil

  @doc "Runs a logical S2S service request with a structured reply sink."
  @spec with_s2s_sink((Message.t() -> term()), (-> result)) :: result when result: var
  def with_s2s_sink(sink, fun) when is_function(sink, 1) and is_function(fun, 0) do
    previous = Process.get(@s2s_sink_key)
    Process.put(@s2s_sink_key, sink)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@s2s_sink_key), else: Process.put(@s2s_sink_key, previous)
    end
  end

  @doc """
  Broadcasts user-originated messages and echoes them back to the sender when the
  `echo-message` capability is enabled for that user.
  """
  @spec broadcast_with_echo(Message.t() | [Message.t()], User.t(), target() | [target()]) :: :ok
  def broadcast_with_echo([], %User{}, _targets), do: :ok

  def broadcast_with_echo(messages, %User{} = sender, targets) do
    if ElixIRCd.Multiline.collecting?() do
      ElixIRCd.Multiline.collect(messages, sender, targets)
    else
      do_broadcast_with_echo(messages, sender, targets)
    end
  end

  defp do_broadcast_with_echo(messages, sender, targets) do
    delivery_targets =
      targets
      |> List.wrap()
      |> Enum.uniq_by(&delivery_identity_key/1)

    echo_enabled? = echo_message_enabled?(sender)

    self_delivery? = Enum.any?(delivery_targets, &same_delivery_target?(&1, sender))
    separate_echo? = echo_enabled?

    any_message_tags? =
      ((echo_enabled? or self_delivery?) and message_tags_capable?(sender)) or
        Enum.any?(delivery_targets, &message_tags_capable?/1)

    Enum.each(List.wrap(messages), fn message ->
      prepared = prepare_message(message, sender, any_message_tags? or History.enabled?())
      prepared = maybe_put_history_time(prepared)
      History.record(prepared, sender)
      send_delivery_messages(prepared, delivery_targets, sender)

      if separate_echo?, do: broadcast_to_target(prepared, sender, sender)
    end)

    if self_delivery?, do: ResponseContext.mark_response_satisfied(sender.pid)

    :ok
  end

  @doc false
  @spec prepare_multiline_message(Message.t(), User.t()) :: Message.t()
  def prepare_multiline_message(message, sender) do
    message
    |> add_context(sender)
    |> StandardReply.fit_message()
  end

  @spec prepare_message(message(), context(), boolean()) :: Message.t()
  defp prepare_message(%StandardReply{} = reply, context, any_message_tags?) do
    reply
    |> StandardReply.to_message()
    |> prepare_message(context, any_message_tags?)
  end

  defp prepare_message(message, context, any_message_tags?) do
    message
    |> add_context(context)
    |> StandardReply.fit_message()
    |> maybe_put_base_msgid(any_message_tags?)
  end

  @spec message_tags_capable?(target()) :: boolean()
  defp message_tags_capable?(%User{capabilities: capabilities}) do
    "message-tags" in capabilities
  end

  defp message_tags_capable?(_pid), do: false

  @spec send_delivery_messages(Message.t(), [target()], User.t()) :: :ok
  defp send_delivery_messages(message, targets, sender) do
    Enum.each(targets, fn target -> send_delivery_message(message, target, sender) end)
  end

  @spec send_delivery_message(Message.t(), target(), User.t()) :: :ok
  defp send_delivery_message(message, target, %User{} = sender) do
    if same_delivery_target?(target, sender) do
      send_prepared_message(message, sender)
    else
      broadcast_to_target(message, target, sender)
    end
  end

  @spec echo_message_enabled?(User.t()) :: boolean()
  defp echo_message_enabled?(%User{capabilities: capabilities}) do
    echo_message_supported = Application.fetch_env!(:elixircd, :capabilities)[:echo_message]
    echo_message_supported and "echo-message" in capabilities
  end

  defp delivery_identity_key(%User{uid: uid}) when is_binary(uid), do: {:uid, uid}
  defp delivery_identity_key(%User{pid: pid}) when is_pid(pid), do: {:pid, pid}
  defp delivery_identity_key(pid) when is_pid(pid), do: {:pid, pid}
  defp delivery_identity_key(_target), do: {:unidentified, make_ref()}

  defp same_delivery_target?(%User{} = left, %User{} = right), do: User.same_identity?(left, right)
  defp same_delivery_target?(%User{pid: pid}, target) when is_pid(pid), do: same_delivery_target?(pid, target)
  defp same_delivery_target?(target, %User{pid: pid}) when is_pid(pid), do: same_delivery_target?(target, pid)
  defp same_delivery_target?(left, right) when is_pid(left) and is_pid(right), do: left == right
  defp same_delivery_target?(_left, _right), do: false

  @spec source_user_from_context(context()) :: User.t() | nil
  defp source_user_from_context(%User{} = user), do: user
  defp source_user_from_context(_context), do: nil

  @spec broadcast_to_target(Message.t(), target(), User.t() | nil) :: :ok
  defp broadcast_to_target(message, %User{} = user, _source_user) do
    maybe_send_to_user(message, user)
  end

  defp broadcast_to_target(message, pid, source_user) when is_pid(pid) do
    case source_user do
      %User{pid: ^pid} = user ->
        maybe_send_to_user(message, user)

      _other ->
        send_message(message, pid)
    end
  end

  @spec maybe_send_to_user(Message.t(), User.t()) :: :ok
  defp maybe_send_to_user(message, %User{capabilities: []} = user) do
    send_prepared_message(%{message | tags: %{}}, user)
  end

  defp maybe_send_to_user(message, %User{capabilities: capabilities} = user) do
    if "batch" in capabilities and ResponseContext.buffer(message, user) == :buffered do
      :ok
    else
      send_prepared_message(message, user)
    end
  end

  @spec send_message(Message.t(), pid()) :: :ok
  defp send_message(message, pid) do
    message
    |> Message.unparse!()
    |> then(&Connection.handle_send(pid, &1))
  end

  @spec add_context(Message.t(), context()) :: Message.t()
  defp add_context(message, %User{modes: modes} = user) do
    message =
      message
      |> sanitize_client_message_tags(user)
      |> add_prefix(user)
      |> maybe_put_bot_tag(modes)
      |> maybe_put_account_tag(user)

    message
  end

  defp add_context(message, context) do
    add_prefix(message, context)
  end

  @spec add_prefix(Message.t(), context() | String.t()) :: Message.t()
  defp add_prefix(%Message{} = message, %User{} = user), do: %{message | prefix: user_mask(user)}
  defp add_prefix(%Message{} = message, :server), do: %{message | prefix: server_prefix()}
  defp add_prefix(%Message{} = message, :chanserv), do: %{message | prefix: Service.mask(:chanserv)}
  defp add_prefix(%Message{} = message, :nickserv), do: %{message | prefix: Service.mask(:nickserv)}
  defp add_prefix(%Message{} = message, nil), do: message

  @spec sanitize_client_message_tags(Message.t(), User.t()) :: Message.t()
  defp sanitize_client_message_tags(%Message{tags: tags} = message, %User{capabilities: capabilities}) do
    sanitized_tags =
      if "message-tags" in capabilities do
        relayable_client_tags(tags)
      else
        %{}
      end

    %{message | tags: sanitized_tags}
  end

  @spec maybe_put_bot_tag(Message.t(), [String.t()]) :: Message.t()
  defp maybe_put_bot_tag(%Message{} = message, modes) do
    if :B in modes do
      %{message | tags: Map.put(message.tags, "bot", nil)}
    else
      message
    end
  end

  @spec maybe_put_account_tag(Message.t(), User.t()) :: Message.t()
  defp maybe_put_account_tag(%Message{} = message, %User{identified_as: nil}), do: message

  defp maybe_put_account_tag(%Message{} = message, %User{identified_as: account}) do
    account_tag_supported = Application.fetch_env!(:elixircd, :capabilities)[:account_tag]

    if account_tag_supported do
      %{message | tags: Map.put(message.tags, "account", account)}
    else
      message
    end
  end

  @spec maybe_put_base_msgid(Message.t(), boolean()) :: Message.t()
  defp maybe_put_base_msgid(%Message{} = message, false), do: message

  defp maybe_put_base_msgid(%Message{} = message, true) do
    if History.recordable?(message) do
      put_msgid(message)
    else
      message
    end
  end

  defp put_msgid(%Message{tags: tags} = message) do
    msgid_supported = Application.fetch_env!(:elixircd, :message_ids)[:enabled]

    if msgid_supported and not Map.has_key?(tags, "msgid") do
      msgid =
        :crypto.strong_rand_bytes(18)
        |> Base.url_encode64(padding: false)

      %{message | tags: Map.put(tags, "msgid", msgid)}
    else
      message
    end
  end

  defp maybe_put_history_time(%Message{} = message) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    %{message | tags: Map.put_new(message.tags, "time", timestamp)}
  end

  @spec filter_tags(Message.t(), User.t()) :: Message.t()
  defp filter_tags(message, %User{capabilities: []}), do: %{message | tags: %{}}

  defp filter_tags(%Message{tags: tags} = message, %User{capabilities: caps}) when map_size(tags) == 0 do
    if "server-time" in caps do
      %{message | tags: maybe_put_server_time_tag(tags, caps)}
    else
      message
    end
  end

  defp filter_tags(message, %User{capabilities: capabilities}) do
    if recipient_supports_message_tags?(capabilities) do
      tags =
        message.tags
        |> maybe_filter_client_only_tags(capabilities)
        |> maybe_put_server_time_tag(capabilities)
        |> maybe_filter_msgid_tag(capabilities)
        |> maybe_filter_account_tag(capabilities)
        |> maybe_filter_batch_tag(capabilities)
        |> maybe_filter_label_tag(capabilities)

      %{message | tags: tags}
    else
      %{message | tags: %{}}
    end
  end

  @spec recipient_supports_message_tags?([String.t()]) :: boolean()
  defp recipient_supports_message_tags?(capabilities) do
    Enum.any?(
      capabilities,
      &(&1 in ["message-tags", "account-tag", "server-time", "batch", "labeled-response"])
    )
  end

  @spec maybe_filter_client_only_tags(Message.tags(), [String.t()]) :: Message.tags()
  defp maybe_filter_client_only_tags(tags, capabilities) do
    if "message-tags" in capabilities do
      tags
    else
      Map.reject(tags, fn {tag_name, _value} -> String.starts_with?(tag_name, "+") end)
    end
  end

  @spec maybe_put_server_time_tag(Message.tags(), [String.t()]) :: Message.tags()
  defp maybe_put_server_time_tag(tags, capabilities) do
    server_time_supported = Application.fetch_env!(:elixircd, :capabilities)[:server_time]

    cond do
      not server_time_supported or "server-time" not in capabilities ->
        Map.delete(tags, "time")

      Map.has_key?(tags, "time") ->
        tags

      true ->
        time =
          DateTime.utc_now()
          |> DateTime.truncate(:millisecond)
          |> DateTime.to_iso8601()

        Map.put(tags, "time", time)
    end
  end

  @spec maybe_filter_msgid_tag(Message.tags(), [String.t()]) :: Message.tags()
  defp maybe_filter_msgid_tag(tags, _capabilities) when not is_map_key(tags, "msgid"), do: tags

  defp maybe_filter_msgid_tag(tags, capabilities) do
    msgid_supported = Application.fetch_env!(:elixircd, :message_ids)[:enabled]

    cond do
      not msgid_supported -> Map.delete(tags, "msgid")
      "message-tags" not in capabilities -> Map.delete(tags, "msgid")
      true -> tags
    end
  end

  @spec maybe_filter_account_tag(Message.tags(), [String.t()]) :: Message.tags()
  defp maybe_filter_account_tag(tags, _capabilities) when not is_map_key(tags, "account"), do: tags

  defp maybe_filter_account_tag(tags, capabilities) do
    account_tag_supported = Application.fetch_env!(:elixircd, :capabilities)[:account_tag]

    cond do
      not account_tag_supported -> Map.delete(tags, "account")
      "account-tag" not in capabilities -> Map.delete(tags, "account")
      true -> tags
    end
  end

  @spec maybe_filter_batch_tag(Message.tags(), [String.t()]) :: Message.tags()
  defp maybe_filter_batch_tag(tags, _capabilities) when not is_map_key(tags, "batch"), do: tags

  defp maybe_filter_batch_tag(tags, capabilities) do
    if "batch" in capabilities, do: tags, else: Map.delete(tags, "batch")
  end

  @spec maybe_filter_label_tag(Message.tags(), [String.t()]) :: Message.tags()
  defp maybe_filter_label_tag(tags, _capabilities) when not is_map_key(tags, "label"), do: tags

  defp maybe_filter_label_tag(tags, capabilities) do
    if "labeled-response" in capabilities, do: tags, else: Map.delete(tags, "label")
  end

  @spec relayable_client_tags(Message.tags()) :: Message.tags()
  defp relayable_client_tags(tags) do
    Map.filter(tags, fn {tag_name, _value} -> String.starts_with?(tag_name, "+") end)
  end
end
