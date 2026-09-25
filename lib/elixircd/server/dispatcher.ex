defmodule ElixIRCd.Server.Dispatcher do
  @moduledoc """
  Module for dispatching messages to users.
  """

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Service
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User

  @type target :: pid() | User.t()
  @type context :: :server | :chanserv | :nickserv | User.t() | nil
  @type message :: Message.t() | StandardReply.t()

  @doc """
  Broadcasts messages with context to the given targets.

  Standard replies are converted to messages before preparation. This function does not require `standard-replies`, so
  extension-mandated replies can use it.
  """
  @spec broadcast(message() | [message()], context(), target() | [target()]) :: :ok
  def broadcast(messages, context, targets), do: do_broadcast(messages, context, targets, true)

  @doc "Relays synthetic protocol messages with normal source tags, without persisting them as chat history."
  @spec broadcast_without_history(message() | [message()], context(), target() | [target()]) :: :ok
  def broadcast_without_history(messages, context, targets), do: do_broadcast(messages, context, targets, false)

  defp do_broadcast(messages, context, targets, persist_history?) do
    messages = List.wrap(messages)
    targets = List.wrap(targets)
    source_user = source_user_from_context(context)

    if messages == [] or targets == [] do
      :ok
    else
      any_message_tags? = Enum.any?(targets, &message_tags_capable?/1)

      Enum.each(messages, &broadcast_message(&1, context, targets, source_user, any_message_tags?, persist_history?))
    end
  end

  defp broadcast_message(message, context, targets, source_user, any_message_tags?, persist_history?) do
    observe_authentication_reply(message)

    record_history? =
      persist_history? and match?(%User{}, context) and History.enabled?() and History.recordable?(message)

    prepared = prepare_message(message, context, any_message_tags? or record_history?)
    prepared = if record_history?, do: maybe_put_history_time(prepared), else: prepared
    if record_history?, do: History.record(prepared, context)
    if source_user, do: observe_delivery(prepared, length(targets))
    Enum.each(targets, &broadcast_to_target(prepared, &1, source_user))
  end

  defp observe_authentication_reply(%Message{command: :err_saslfail}),
    do: Observability.defer([:authentication], %{count: 1}, %{method: :sasl, result: :failure})

  defp observe_authentication_reply(%Message{command: :rpl_saslsuccess}),
    do: Observability.defer([:authentication], %{count: 1}, %{method: :sasl, result: :success})

  defp observe_authentication_reply(_message), do: :ok

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
  def send_prepared_message(%Message{} = message, %User{pid: pid} = user) do
    message
    |> filter_tags(user)
    |> send_message(pid)
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
  @spec disconnect(User.t(), String.t()) :: :ok
  def disconnect(%User{pid: pid} = user, reason) do
    ResponseContext.flush(user)
    send(pid, {:disconnect, reason})
    :ok
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
      |> Enum.uniq_by(&target_pid/1)

    echo_enabled? = echo_message_enabled?(sender)

    self_delivery? = Enum.any?(delivery_targets, &(target_pid(&1) == sender.pid))
    separate_echo? = echo_enabled?

    any_message_tags? =
      ((echo_enabled? or self_delivery?) and message_tags_capable?(sender)) or
        Enum.any?(delivery_targets, &message_tags_capable?/1)

    Enum.each(List.wrap(messages), fn message ->
      prepared = prepare_message(message, sender, any_message_tags? or History.enabled?())
      prepared = maybe_put_history_time(prepared)
      History.record(prepared, sender)
      observe_delivery(prepared, length(delivery_targets) + if(separate_echo?, do: 1, else: 0))
      send_delivery_messages(prepared, delivery_targets, sender)

      if separate_echo?, do: broadcast_to_target(prepared, sender, sender)
    end)

    if self_delivery?, do: ResponseContext.mark_response_satisfied(sender.pid)

    :ok
  end

  defp observe_delivery(%Message{command: command}, recipients) when command in ["PRIVMSG", "NOTICE", "TAGMSG"] do
    Observability.defer([:message], %{count: 1, recipients: recipients}, %{kind: command})
  end

  defp observe_delivery(_message, _recipients), do: :ok

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
  defp send_delivery_message(message, target, %User{pid: sender_pid} = sender) do
    if target_pid(target) == sender_pid do
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

  @spec target_pid(target()) :: pid()
  defp target_pid(%User{pid: pid}), do: pid
  defp target_pid(pid) when is_pid(pid), do: pid

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
  defp maybe_send_to_user(message, %User{capabilities: [], pid: pid}) do
    send_message(%{message | tags: %{}}, pid)
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
