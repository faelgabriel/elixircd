defmodule ElixIRCd.Server.ResponseContext do
  @moduledoc """
  Buffers replies to one client command so IRCv3 labeled responses can be
  emitted as one logical response.

  Messages for other clients are never buffered. This keeps channel and direct
  message delivery immediate while allowing the requesting client response to
  be encoded as an `ACK`, one labeled message, or a batch.

  The context belongs to the process executing the command and is restored in
  an `after` block. Handlers run synchronously in the connection process; tasks
  must not inherit or reuse this context. Rendering uses immutable event data.

  Clients without batch support bypass context allocation. Large responses are
  emitted in chunks of at most 64 events, retaining the open batch stack until
  finalization. This bounds this module's extra buffer, not the transport queue
  or data collected by an individual command handler.
  """

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @context_key {__MODULE__, :context}
  @max_label_bytes 64
  @max_buffered_events 64

  @type batch :: %{ref: String.t(), type: String.t(), params: [String.t()]}
  @type event :: {:message, Message.t(), User.t()} | {:batch_start, batch()} | {:batch_end, batch()}

  @type t :: %{
          request_user: User.t(),
          label: String.t() | nil,
          batch_capable?: boolean(),
          buffering?: boolean(),
          events_rev: [event()],
          event_count: non_neg_integer(),
          manual_batches: [batch()],
          stream_batches: [batch()] | nil,
          response_satisfied?: boolean(),
          flushed?: boolean()
        }

  @doc """
  Runs a synchronous command with an isolated response context and finalizes
  its replies before returning the handler's result.
  """
  @spec with_command(User.t(), Message.t(), (-> result)) :: result when result: var
  def with_command(%User{} = user, %Message{} = message, fun) when is_function(fun, 0) do
    if "batch" in user.capabilities do
      with_context(user, message, fun)
    else
      without_context(fun)
    end
  end

  @spec without_context((-> result)) :: result when result: var
  defp without_context(fun) do
    case current() do
      nil ->
        fun.()

      previous_context ->
        Process.delete(@context_key)

        try do
          fun.()
        after
          restore(previous_context)
        end
    end
  end

  @spec with_context(User.t(), Message.t(), (-> result)) :: result when result: var
  defp with_context(user, message, fun) do
    previous_context = current()
    Process.put(@context_key, build_context(user, message))

    try do
      result = fun.()
      finalize(user)
      result
    catch
      kind, reason ->
        finalize_failed(user)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      restore(previous_context)
    end
  end

  @doc """
  Returns the active context in the calling process, or nil outside a command.
  """
  @spec current() :: t() | nil
  def current, do: Process.get(@context_key)

  @doc """
  Buffers a prepared message when it targets the client whose command is being
  processed. Returns `:send` when the caller must deliver it immediately.
  """
  @spec buffer(Message.t(), User.t()) :: :buffered | :send
  def buffer(%Message{} = message, %User{pid: target_pid} = user) do
    case current() do
      %{
        request_user: %User{pid: ^target_pid},
        buffering?: true,
        flushed?: false
      } = context ->
        put_context(record_event(context, {:message, message, user}))
        :buffered

      _ ->
        :send
    end
  end

  @doc """
  Marks an immediate, deliberately-unlabeled delivery to the requesting client
  as the command response. This is used for self-targeted client messages.
  """
  @spec mark_response_satisfied(pid()) :: :ok
  def mark_response_satisfied(target_pid) when is_pid(target_pid) do
    update_current(fn
      %{request_user: %User{pid: ^target_pid}} = context ->
        %{context | response_satisfied?: true}

      context ->
        context
    end)
  end

  @doc """
  Sends all buffered output immediately and closes this response. CAP uses this
  as its ACK barrier before changing the negotiated capability set. Only the
  requesting user's response can be flushed by this call.
  """
  @spec flush(User.t()) :: :ok
  def flush(%User{pid: pid} = user) do
    case current() do
      %{request_user: %User{pid: ^pid}, flushed?: false} = context ->
        send_rendered(context, user)

        put_context(%{
          context
          | events_rev: [],
            event_count: 0,
            manual_batches: [],
            stream_batches: nil,
            flushed?: true
        })

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Records a batch start for the active command when the client negotiated
  batch support, returning the generated reference. Types must be IRCv3 types
  or use a vendor namespace. Calls outside an active response have no effect.
  """
  @spec start_batch(String.t(), [String.t()]) :: String.t()
  def start_batch(type, params \\ []) when is_binary(type) and is_list(params) do
    batch = %{ref: new_batch_ref(), type: type, params: params}

    update_current(fn
      %{batch_capable?: true, flushed?: false} = context ->
        context = %{
          context
          | buffering?: true,
            manual_batches: [batch | context.manual_batches]
        }

        record_event(context, {:batch_start, batch})

      context ->
        context
    end)

    batch.ref
  end

  @doc """
  Records the end of the innermost manual batch, if one is open.
  """
  @spec end_batch() :: :ok
  def end_batch do
    update_current(fn
      %{batch_capable?: true, flushed?: false} = context ->
        case context.manual_batches do
          [] ->
            context

          [batch | remaining_batches] ->
            record_event(%{context | manual_batches: remaining_batches}, {:batch_end, batch})
        end

      context ->
        context
    end)
  end

  @doc """
  Groups the callback's replies in a manual batch, closing it even if the
  callback raises. Clients without batch support receive ordinary replies.
  """
  @spec with_batch(String.t(), [String.t()], (-> result)) :: result when result: var
  def with_batch(type, params \\ [], fun) when is_function(fun, 0) do
    start_batch(type, params)

    try do
      fun.()
    after
      end_batch()
    end
  end

  @spec build_context(User.t(), Message.t()) :: t()
  defp build_context(%User{} = user, %Message{tags: tags}) do
    capabilities = user.capabilities
    # Configuration controls CAP availability. Negotiated capabilities remain
    # valid until ACK/DEL is sent, including while REHASH finishes its response.
    batch_capable? = "batch" in capabilities
    labeled_response_capable? = batch_capable? and "labeled-response" in capabilities

    label =
      case Map.get(tags, "label") do
        label when is_binary(label) and byte_size(label) in 1..@max_label_bytes ->
          if labeled_response_capable?, do: label

        _invalid_or_missing_label ->
          nil
      end

    %{
      request_user: user,
      label: label,
      batch_capable?: batch_capable?,
      buffering?: is_binary(label),
      events_rev: [],
      event_count: 0,
      manual_batches: [],
      stream_batches: nil,
      response_satisfied?: false,
      flushed?: false
    }
  end

  @spec finalize(User.t()) :: :ok
  defp finalize(%User{} = user) do
    case current() do
      %{flushed?: false} = context -> send_rendered(context, user)
      _ -> :ok
    end
  end

  @spec finalize_failed(User.t()) :: :ok
  defp finalize_failed(%User{} = user) do
    case current() do
      %{events_rev: [_event | _events], flushed?: false} = context -> send_rendered(context, user)
      %{stream_batches: batches, flushed?: false} = context when is_list(batches) -> send_rendered(context, user)
      _ -> :ok
    end
  end

  @spec send_rendered(t(), User.t()) :: :ok
  defp send_rendered(context, fallback_user) do
    context
    |> render_events(fallback_user)
    |> Enum.each(fn {message, recipient} -> Dispatcher.send_prepared_message(message, recipient) end)

    :ok
  end

  @spec render_events(t(), User.t()) :: [{Message.t(), User.t()}]
  defp render_events(%{stream_batches: batches} = context, user) when is_list(batches) do
    {messages, remaining_batches} =
      context |> events_with_closed_batches() |> render_event_stream(user, batches, nil)

    case remaining_batches do
      [] -> messages
      [outer] -> messages ++ [{batch_end_message(outer, []), user}]
    end
  end

  defp render_events(%{label: nil} = context, fallback_user) do
    context
    |> events_with_closed_batches()
    |> render_event_stream(fallback_user, [], nil)
    |> elem(0)
  end

  defp render_events(%{events_rev: [], response_satisfied?: true}, _fallback_user), do: []

  defp render_events(%{events_rev: [], label: label}, fallback_user) do
    message = %Message{prefix: hostname(), command: "ACK", params: [], tags: %{"label" => label}}
    [{message, fallback_user}]
  end

  defp render_events(%{label: label} = context, fallback_user) do
    closed_events = events_with_closed_batches(context)

    case top_level_logical_messages(closed_events) do
      1 -> closed_events |> render_event_stream(fallback_user, [], label) |> elem(0)
      _many -> render_labeled_batch(context, fallback_user)
    end
  end

  @spec render_labeled_batch(t(), User.t()) :: [{Message.t(), User.t()}]
  defp render_labeled_batch(%{label: label} = context, fallback_user) do
    outer = %{ref: new_batch_ref(), type: "labeled-response", params: []}
    start = batch_start_message(outer, [], label)
    {contents, _batches} = context |> events_with_closed_batches() |> render_event_stream(fallback_user, [outer], nil)
    finish = batch_end_message(outer, [])

    [{start, fallback_user} | contents] ++ [{finish, fallback_user}]
  end

  @spec record_event(t(), event()) :: t()
  defp record_event(context, event) do
    context = %{context | events_rev: [event | context.events_rev], event_count: context.event_count + 1}

    if context.event_count >= @max_buffered_events, do: emit_chunk(context), else: context
  end

  @spec emit_chunk(t()) :: t()
  defp emit_chunk(context) do
    batches = stream_batches(context)
    user = context.request_user
    {messages, open_batches} = context.events_rev |> Enum.reverse() |> render_event_stream(user, batches, nil)
    Enum.each(messages, fn {message, recipient} -> Dispatcher.send_prepared_message(message, recipient) end)
    %{context | events_rev: [], event_count: 0, stream_batches: open_batches}
  end

  @spec stream_batches(t()) :: [batch()]
  defp stream_batches(%{stream_batches: batches}) when is_list(batches), do: batches
  defp stream_batches(%{label: nil}), do: []

  defp stream_batches(%{label: label, request_user: user}) do
    batch = %{ref: new_batch_ref(), type: "labeled-response", params: []}
    Dispatcher.send_prepared_message(batch_start_message(batch, [], label), user)
    [batch]
  end

  @spec events_with_closed_batches(t()) :: [event()]
  defp events_with_closed_batches(%{events_rev: events_rev, manual_batches: manual_batches}) do
    Enum.reverse(events_rev) ++ Enum.map(manual_batches, &{:batch_end, &1})
  end

  @spec render_event_stream([event()], User.t(), [batch()], String.t() | nil) ::
          {[{Message.t(), User.t()}], [batch()]}
  defp render_event_stream(events, fallback_user, initial_batches, direct_label) do
    {rendered_rev, open_batches, _label_used?} =
      Enum.reduce(events, {[], initial_batches, false}, fn event, {messages, open_batches, label_used?} ->
        label = if label_used?, do: nil, else: direct_label

        case event do
          {:batch_start, batch} ->
            message = batch_start_message(batch, open_batches, label)
            {[{message, fallback_user} | messages], [batch | open_batches], label_used? or is_binary(label)}

          {:batch_end, batch} ->
            [_current_batch | enclosing_batches] = open_batches
            message = batch_end_message(batch, enclosing_batches)
            {[{message, fallback_user} | messages], enclosing_batches, label_used?}

          {:message, message, recipient} ->
            tags =
              message.tags
              |> maybe_put_batch_tag(open_batches)
              |> maybe_put_label(label)

            rendered_message = %{message | tags: tags}
            {[{rendered_message, recipient} | messages], open_batches, label_used? or is_binary(label)}
        end
      end)

    {Enum.reverse(rendered_rev), open_batches}
  end

  @spec top_level_logical_messages([event()]) :: non_neg_integer()
  defp top_level_logical_messages(events) do
    {count, _depth} =
      Enum.reduce(events, {0, 0}, fn
        {:batch_start, _batch}, {count, 0} -> {count + 1, 1}
        {:batch_start, _batch}, {count, depth} -> {count, depth + 1}
        {:batch_end, _batch}, {count, depth} -> {count, max(depth - 1, 0)}
        {:message, _message, _recipient}, {count, 0} -> {count + 1, 0}
        {:message, _message, _recipient}, state -> state
      end)

    count
  end

  @spec batch_start_message(batch(), [batch()], String.t() | nil) :: Message.t()
  defp batch_start_message(batch, enclosing_batches, label) do
    tags = %{} |> maybe_put_batch_tag(enclosing_batches) |> maybe_put_label(label)

    %Message{
      tags: tags,
      prefix: hostname(),
      command: "BATCH",
      params: ["+" <> batch.ref, batch.type | batch.params]
    }
  end

  @spec batch_end_message(batch(), [batch()]) :: Message.t()
  defp batch_end_message(batch, enclosing_batches) do
    %Message{
      tags: maybe_put_batch_tag(%{}, enclosing_batches),
      prefix: hostname(),
      command: "BATCH",
      params: ["-" <> batch.ref]
    }
  end

  @spec maybe_put_batch_tag(Message.tags(), [batch()]) :: Message.tags()
  defp maybe_put_batch_tag(tags, []), do: tags
  defp maybe_put_batch_tag(tags, [batch | _enclosing_batches]), do: Map.put(tags, "batch", batch.ref)

  @spec maybe_put_label(Message.tags(), String.t() | nil) :: Message.tags()
  defp maybe_put_label(tags, label) when is_binary(label), do: Map.put(tags, "label", label)
  defp maybe_put_label(tags, _label), do: tags

  @spec update_current((t() -> t())) :: :ok
  defp update_current(fun) when is_function(fun, 1) do
    case current() do
      nil -> :ok
      context -> put_context(fun.(context))
    end
  end

  @spec put_context(t()) :: :ok
  defp put_context(context) do
    Process.put(@context_key, context)
    :ok
  end

  @spec restore(t() | nil) :: :ok
  defp restore(nil) do
    Process.delete(@context_key)
    :ok
  end

  defp restore(context), do: put_context(context)

  @spec hostname() :: String.t()
  defp hostname, do: Application.fetch_env!(:elixircd, :server)[:hostname]

  @spec new_batch_ref() :: String.t()
  defp new_batch_ref do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string(36)
  end
end
