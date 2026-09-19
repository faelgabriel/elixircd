defmodule ElixIRCd.Multiline do
  @moduledoc "Validation, buffering and delivery for IRCv3 multiline client batches."

  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ClientBatches
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.ClientBatch
  alias ElixIRCd.Tables.User

  @concat_tag "draft/multiline-concat"
  @delivery_key {__MODULE__, :delivery}

  @doc "Captures a message into the connection's active client batch when applicable."
  @spec capture(User.t(), Message.t()) :: :continue | :handled
  def capture(_user, %Message{command: "BATCH"}), do: :continue

  def capture(user, %Message{tags: %{"batch" => reference}} = message) do
    case ClientBatches.get(user.pid, reference) do
      {:ok, batch} ->
        append_line(user, batch, message)

      {:error, :client_batch_not_found} ->
        case ClientBatches.for_user(user.pid) do
          [batch | _] -> invalidate(user, batch, "MULTILINE_INVALID", [], "Unexpected batch reference")
          [] -> :ok
        end
    end

    :handled
  end

  def capture(_user, _message), do: :continue

  @doc "Starts a bounded client-originated multiline batch."
  @spec start(User.t(), String.t(), String.t(), Message.tags()) :: :ok
  def start(user, reference, target, tags) do
    config = Application.fetch_env!(:elixircd, :multiline)

    cond do
      not config[:enabled] or "draft/multiline" not in user.capabilities ->
        fail(user, "MULTILINE_INVALID", [], "Multiline capability is required")

      reference == "" or target == "" or String.contains?(target, ",") or ClientBatches.for_user(user.pid) != [] ->
        fail(user, "MULTILINE_INVALID", [], "A multiline batch is already active or invalid")

      true ->
        ClientBatches.create(%{
          id: {user.pid, reference},
          user_pid: user.pid,
          reference: reference,
          target: target,
          lines: [],
          bytes: 0,
          invalid: false,
          tags: Map.drop(tags, ["batch"])
        })

        :ok
    end
  end

  @doc "Finishes and atomically delivers a client-originated multiline batch."
  @spec finish(User.t(), String.t()) :: :ok
  def finish(user, reference) do
    case ClientBatches.get(user.pid, reference) do
      {:ok, batch} ->
        ClientBatches.delete(batch)
        if not batch.invalid and batch.lines != [], do: deliver(user, batch)
        :ok

      {:error, :client_batch_not_found} ->
        fail(user, "MULTILINE_INVALID", [], "Unknown multiline batch")
    end
  end

  @doc "Reports whether the current command process is collecting atomic multiline delivery."
  @spec collecting?() :: boolean()
  def collecting?, do: is_map(Process.get(@delivery_key))

  @doc "Collects prepared delivery records while validating an atomic multiline message."
  @spec collect(Message.t() | [Message.t()], User.t(), User.t() | [User.t()]) :: :ok
  def collect(messages, sender, targets) do
    state = Process.get(@delivery_key)

    records =
      Enum.map(List.wrap(messages), fn message ->
        prepared = Dispatcher.prepare_multiline_message(message, sender)

        prepared =
          if Map.has_key?(message.tags, @concat_tag) do
            %{prepared | tags: Map.put(prepared.tags, @concat_tag, nil)}
          else
            prepared
          end

        {prepared, delivery_targets(sender, targets)}
      end)

    Process.put(@delivery_key, %{state | records: state.records ++ records})
    :ok
  end

  defp append_line(user, batch, message) do
    config = Application.fetch_env!(:elixircd, :multiline)
    text = message.trailing || message.params |> Enum.drop(1) |> Enum.join(" ")
    line_count = length(batch.lines) + 1
    total_bytes = batch.bytes + byte_size(text)

    case validate_line(batch, message, text, line_count, total_bytes, config) do
      :ignore -> :ok
      {:error, code, context, description} -> invalidate(user, batch, code, context, description)
      :ok -> store_line(batch, message, total_bytes)
    end
  end

  defp validate_line(batch, message, text, line_count, total_bytes, config) do
    cond do
      batch.invalid ->
        :ignore

      not valid_line_target?(batch, message) ->
        invalid_line("All lines must use one target and message command")

      Map.has_key?(message.tags, @concat_tag) and text == "" ->
        invalid_line("A blank line cannot use multiline-concat")

      line_count > config[:max_lines] ->
        limit_error("MULTILINE_MAX_LINES", config[:max_lines], "Multiline line limit exceeded")

      total_bytes > config[:max_bytes] ->
        limit_error("MULTILINE_MAX_BYTES", config[:max_bytes], "Multiline byte limit exceeded")

      batch.command not in [nil, message.command] ->
        invalid_line("All lines must use the same command")

      true ->
        :ok
    end
  end

  defp valid_line_target?(batch, message),
    do: message.command in ["PRIVMSG", "NOTICE"] and List.first(message.params) == batch.target

  defp invalid_line(description), do: {:error, "MULTILINE_INVALID", [], description}

  defp limit_error(code, limit, description),
    do: {:error, code, [Integer.to_string(limit)], description}

  defp store_line(batch, message, total_bytes) do
    ClientBatches.update(batch, %{
      command: message.command,
      lines: batch.lines ++ [%{message | tags: Map.delete(message.tags, "batch")}],
      bytes: total_bytes
    })

    :ok
  end

  defp invalidate(user, batch, code, context, description) do
    ClientBatches.update(batch, %{invalid: true})
    fail(user, code, context, description)
  end

  defp deliver(user, %ClientBatch{} = batch) do
    previous = Process.get(@delivery_key)
    Process.put(@delivery_key, %{batch: batch, records: [], failed: false})

    try do
      _delivery_result =
        Enum.reduce_while(batch.lines, :ok, fn line, :ok ->
          before_count = Process.get(@delivery_key).records |> length()
          ElixIRCd.Command.dispatch(user, line)
          after_count = Process.get(@delivery_key).records |> length()

          if after_count > before_count do
            {:cont, :ok}
          else
            Process.put(@delivery_key, %{Process.get(@delivery_key) | failed: true})
            {:halt, :error}
          end
        end)

      state = Process.get(@delivery_key)
      if not state.failed, do: send_collected(user, batch, state.records)
    after
      if previous, do: Process.put(@delivery_key, previous), else: Process.delete(@delivery_key)
    end
  end

  defp send_collected(sender, batch, records) do
    msgid = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    History.record_multiline(sender, batch, records, msgid, timestamp)

    records
    |> Enum.flat_map(fn {_message, recipients} -> recipients end)
    |> Enum.uniq_by(& &1.pid)
    |> Enum.each(fn recipient ->
      recipient_records =
        Enum.filter(records, fn {_message, recipients} -> Enum.any?(recipients, &(&1.pid == recipient.pid)) end)

      if "draft/multiline" in recipient.capabilities and "batch" in recipient.capabilities do
        send_batch(recipient, sender, batch, recipient_records, msgid, timestamp)
      else
        send_fallback(recipient, batch, recipient_records, msgid, timestamp)
      end
    end)

    :ok
  end

  defp send_batch(recipient, sender, batch, records, msgid, timestamp) do
    reference = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)

    start_tags =
      batch.tags
      |> Map.drop(["batch"])
      |> Map.put("msgid", msgid)
      |> Map.put("time", timestamp)
      |> maybe_keep_label(recipient, sender)

    %Message{
      prefix: ElixIRCd.Utils.Protocol.user_mask(sender),
      command: "BATCH",
      params: ["+" <> reference, "draft/multiline", batch.target],
      tags: start_tags
    }
    |> Dispatcher.send_prepared_message(recipient)

    Enum.each(records, fn {message, _recipients} ->
      %{message | tags: message.tags |> Map.drop(["label", "msgid", "time"]) |> Map.put("batch", reference)}
      |> Dispatcher.send_prepared_message(recipient)
    end)

    %Message{prefix: ElixIRCd.Utils.Protocol.user_mask(sender), command: "BATCH", params: ["-" <> reference]}
    |> Dispatcher.send_prepared_message(recipient)
  end

  defp send_fallback(recipient, batch, records, msgid, timestamp) do
    records
    |> Enum.reject(fn {message, _recipients} -> (message.trailing || "") == "" end)
    |> Enum.with_index()
    |> Enum.each(fn {{message, _recipients}, index} ->
      tags =
        message.tags
        |> Map.drop(["batch", @concat_tag, "label", "msgid", "time"])
        |> Map.merge(Map.drop(batch.tags, ["batch", "label"]))
        |> Map.put("time", timestamp)
        |> maybe_put_msgid(index, msgid)

      %{message | tags: tags} |> Dispatcher.send_prepared_message(recipient)
    end)
  end

  defp maybe_put_msgid(tags, 0, msgid), do: Map.put(tags, "msgid", msgid)
  defp maybe_put_msgid(tags, _index, _msgid), do: tags

  defp maybe_keep_label(tags, %{pid: pid}, %{pid: pid}), do: tags
  defp maybe_keep_label(tags, _recipient, _sender), do: Map.delete(tags, "label")

  defp delivery_targets(sender, targets) do
    targets = List.wrap(targets) |> Enum.uniq_by(& &1.pid)

    if "echo-message" in sender.capabilities and Enum.all?(targets, &(&1.pid != sender.pid)),
      do: [sender | targets],
      else: targets
  end

  defp fail(user, code, context, description) do
    %StandardReply{type: :fail, command: "BATCH", code: code, context: context, description: description}
    |> Dispatcher.broadcast(:server, user)
  end
end
