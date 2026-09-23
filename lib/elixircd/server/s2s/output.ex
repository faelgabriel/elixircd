defmodule ElixIRCd.Server.S2S.Output do
  @moduledoc """
  Bounded committed-output collector.

  A collector belongs to one local ordering authority. An attempt is disposable
  transaction-local data; only `commit/3` turns it into a durable output group.
  The module never performs socket, mailbox, audit or job work, which keeps a
  Mnesia retry from escaping an external effect.
  """

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Tables.NativeOutputControl
  alias ElixIRCd.Tables.NativeOutputGroup

  @attempt_key {__MODULE__, :attempt}
  @draining_sequences_key {__MODULE__, :draining_sequences}
  @control_key "local"

  @type attempt :: %{
          generation: Identity.id(),
          intents: [map()],
          count: non_neg_integer(),
          bytes: non_neg_integer(),
          max_bytes: pos_integer(),
          max_intents: pos_integer()
        }

  @type group :: %{
          sequence: pos_integer(),
          generation: Identity.id(),
          intents: [map()],
          bytes: pos_integer(),
          destinations: [term()]
        }

  @type t :: %{
          generation: Identity.id(),
          next_sequence: pos_integer(),
          groups: :queue.queue(group()),
          bytes: non_neg_integer(),
          max_bytes: pos_integer(),
          max_groups: pos_integer()
        }

  @doc "Creates an empty collector for one output generation."
  @spec new(Identity.id(), keyword()) :: t()
  def new(generation, options \\ []) do
    %{
      generation: generation,
      next_sequence: 1,
      groups: :queue.new(),
      bytes: 0,
      max_bytes: Keyword.get(options, :max_bytes, 128 * 1_048_576),
      max_groups: Keyword.get(options, :max_groups, 65_536)
    }
  end

  @doc "Starts a fresh attempt; callers must invoke this again after a retry."
  @spec attempt(Identity.id(), keyword()) :: attempt()
  def attempt(generation, options \\ []) do
    %{
      generation: generation,
      intents: [],
      count: 0,
      bytes: 0,
      max_bytes: Keyword.get(options, :max_bytes, 16 * 1_048_576),
      max_intents: Keyword.get(options, :max_intents, 65_536)
    }
  end

  @doc "Collects one immutable intent in the current transaction attempt."
  @spec collect(attempt(), map()) :: {:ok, attempt()} | {:error, term()}
  def collect(%{intents: intents, count: count} = attempt, intent) when is_map(intent) do
    bytes = intent_budget_bytes(intent)

    cond do
      count >= attempt.max_intents ->
        {:error, :output_intent_capacity}

      attempt.bytes + bytes > attempt.max_bytes ->
        {:error, :output_attempt_bytes}

      true ->
        {:ok, %{attempt | intents: [intent | intents], count: count + 1, bytes: attempt.bytes + bytes}}
    end
  end

  def collect(_attempt, _intent), do: {:error, :invalid_output_intent}

  # This is deliberately a bounded structural estimate. Serializing the whole
  # intent just to account for it would put avoidable work inside a retried
  # Mnesia transaction; the destination writer applies the exact wire limit.
  defp intent_budget_bytes(term), do: 64 + intent_term_bytes(term)

  defp intent_term_bytes(term) when is_binary(term), do: 16 + byte_size(term) * 2
  defp intent_term_bytes(term) when is_integer(term), do: 16
  defp intent_term_bytes(term) when is_float(term), do: 24
  defp intent_term_bytes(nil), do: 16
  defp intent_term_bytes(term) when is_atom(term), do: 24

  defp intent_term_bytes(term) when is_map(term) do
    64 +
      Enum.reduce(Map.to_list(term), 0, fn {key, value}, bytes ->
        bytes + 24 + intent_term_bytes(key) + intent_term_bytes(value)
      end)
  end

  defp intent_term_bytes(term) when is_list(term) do
    24 + Enum.reduce(term, 0, fn value, bytes -> bytes + intent_term_bytes(value) end)
  end

  defp intent_term_bytes(_term), do: 32

  @doc "Commits one successful attempt to the ordered output queue."
  @spec commit(t(), attempt(), Identity.id()) :: {:ok, t(), group()} | {:error, term()}
  def commit(%{generation: generation} = output, %{generation: generation} = attempt, generation)
      when attempt.intents != [] do
    group = %{
      sequence: output.next_sequence,
      generation: generation,
      intents: Enum.reverse(attempt.intents),
      bytes: attempt.bytes,
      destinations: destinations_for_intents(Enum.reverse(attempt.intents))
    }

    cond do
      :queue.len(output.groups) >= output.max_groups ->
        {:error, :output_group_capacity}

      output.bytes + group.bytes > output.max_bytes ->
        {:error, :output_bytes}

      true ->
        next = %{
          output
          | groups: :queue.in(group, output.groups),
            next_sequence: output.next_sequence + 1,
            bytes: output.bytes + group.bytes
        }

        {:ok, next, group}
    end
  end

  def commit(_output, _attempt, _generation), do: {:error, :stale_output_attempt}

  @doc "Returns the next group only for the current link/output generation."
  @spec peek(t(), Identity.id()) :: {:ok, group()} | :empty | {:error, term()}
  def peek(%{generation: generation} = output, generation) do
    case :queue.peek(output.groups) do
      {:value, group} -> {:ok, group}
      :empty -> :empty
    end
  end

  def peek(_output, _generation), do: {:error, :stale_output_generation}

  @doc "Acknowledges a group after the owner has handed it to its destination writer."
  @spec acknowledge(t(), Identity.id(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def acknowledge(%{generation: generation} = output, generation, sequence) do
    case :queue.out(output.groups) do
      {{:value, %{sequence: ^sequence, bytes: bytes}}, groups} ->
        {:ok, %{output | groups: groups, bytes: output.bytes - bytes}}

      {{:value, _group}, _groups} ->
        {:error, :output_sequence_mismatch}

      {:empty, _groups} ->
        {:error, :output_empty}
    end
  end

  def acknowledge(_output, _generation, _sequence), do: {:error, :stale_output_generation}

  @doc "Invalidates all groups from an old generation after an uncertain write."
  @spec fence(t(), Identity.id()) :: t()
  def fence(output, generation) do
    %{output | generation: generation, next_sequence: 1, groups: :queue.new(), bytes: 0}
  end

  @doc "Returns queue accounting without exposing intent contents."
  @spec stats(t()) :: %{groups: non_neg_integer(), bytes: non_neg_integer(), next_sequence: pos_integer()}
  def stats(output), do: %{groups: :queue.len(output.groups), bytes: output.bytes, next_sequence: output.next_sequence}

  @doc "Runs a Mnesia transaction with an atomically committed output group and post-commit drain."
  @spec transaction((-> result), keyword()) :: result when result: var
  def transaction(fun, options \\ []) when is_function(fun, 0) do
    if Memento.Transaction.inside?() do
      fun.()
    else
      generation = Keyword.get(options, :generation, Identity.nonce())
      attempt_options = Keyword.take(options, [:max_bytes, :max_intents])
      output = new(generation, max_bytes: Keyword.get(options, :aggregate_max_bytes, 128 * 1_048_576))
      drain_fun = Keyword.get(options, :drain_fun, fn _intent -> :ok end)
      persist? = Keyword.get(options, :persist, true)
      drain_error_fun = Keyword.get(options, :on_drain_error, &uncertain_drain/2)

      try do
        {result, attempt, committed_group} =
          committed_transaction(fun, generation, attempt_options, output, persist?, options)

        Process.delete(@attempt_key)

        case attempt do
          %{intents: []} ->
            result

          %{} = attempt ->
            group = drain_group_for_attempt(output, attempt, generation, committed_group)

            case drain_result(group, drain_fun, committed_group && persist?, options) do
              :ok ->
                case if(committed_group && persist?, do: acknowledge_persisted(committed_group.sequence), else: :ok) do
                  :ok ->
                    result

                  {:error, reason} ->
                    _ = safe_drain_error(drain_error_fun, group, reason)
                    {:error, {:output_drain_failed, reason}}
                end

              {:error, reason} ->
                _ = safe_drain_error(drain_error_fun, group, reason)
                {:error, {:output_drain_failed, reason}}
            end
        end
      after
        Process.delete(@attempt_key)
        Process.delete({@attempt_key, :error})
      end
    end
  end

  @doc """
  Commits a bounded output group without draining it in the worker process.

  This is used for expensive authority jobs. The returned group is handed to
  the owning Manager, which performs the real state and socket drain and then
  acknowledges the group. A nil group means that the callback produced no
  external output.
  """
  @spec transaction_deferred((-> result), keyword()) ::
          {:ok, result, group() | nil} | {:error, term()}
        when result: var
  def transaction_deferred(fun, options \\ []) when is_function(fun, 0) do
    if Memento.Transaction.inside?() do
      {:error, :nested_deferred_output_transaction}
    else
      generation = Keyword.get(options, :generation, Identity.nonce())
      attempt_options = Keyword.take(options, [:max_bytes, :max_intents])
      output = new(generation, max_bytes: Keyword.get(options, :aggregate_max_bytes, 128 * 1_048_576))
      persist? = Keyword.get(options, :persist, true)

      if not persist? do
        {:error, :deferred_output_requires_persistence}
      else
        try do
          case committed_transaction(
                 fun,
                 generation,
                 attempt_options,
                 output,
                 true,
                 Keyword.put(options, :deferred, true),
                 :safe
               ) do
            {:ok, {result, attempt, committed_group}} ->
              Process.delete(@attempt_key)

              group =
                case attempt do
                  %{intents: []} -> nil
                  %{} -> committed_group || pure_group(output, attempt, generation)
                end

              {:ok, result, group}

            {:error, {:transaction_aborted, {:output_capacity, reason}}} ->
              {:error, reason}

            {:error, {:transaction_aborted, reason}} ->
              {:error, reason}

            {:error, reason} ->
              {:error, reason}
          end
        after
          Process.delete(@attempt_key)
          Process.delete({@attempt_key, :error})
        end
      end
    end
  end

  @doc "Drains one previously committed group and acknowledges it on success."
  @spec drain_pending(group() | pos_integer(), (map() -> term()), keyword()) :: :ok | {:error, term()}
  def drain_pending(group_or_sequence, drain_fun, options \\ []) when is_function(drain_fun, 1) do
    drain_error_fun = Keyword.get(options, :on_drain_error, &uncertain_drain/2)
    expected = if is_map(group_or_sequence), do: group_or_sequence, else: nil
    sequence = if expected, do: expected.sequence, else: group_or_sequence

    with %{} = group <- pending_group(sequence),
         :ok <- matching_pending_group?(group, expected) do
      case drain_result(group, drain_fun, true, options) do
        :ok ->
          case acknowledge_persisted(group.sequence) do
            :ok ->
              :ok

            {:error, reason} = error ->
              _ = safe_drain_error(drain_error_fun, group, reason)
              error
          end

        {:error, reason} = error ->
          _ = safe_drain_error(drain_error_fun, group, reason)
          error
      end
    else
      nil -> {:error, :output_group_missing}
      {:error, _} = error -> error
      _ -> {:error, :invalid_output_group}
    end
  end

  @doc "Returns committed groups in local FIFO order without exposing queue state."
  @spec pending_groups() :: [group()]
  def pending_groups do
    transaction_read(fn ->
      NativeOutputGroup
      |> Memento.Query.all()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&group_from_record/1)
    end)
  rescue
    _ -> []
  end

  @doc "Fences and removes all groups left by an uncertain local output generation."
  @spec fence_pending() :: {:ok, non_neg_integer()} | {:error, term()}
  def fence_pending, do: fence_pending(:all)

  @doc "Fences only groups that can write to one affected destination scope."
  @spec fence_pending(:all | [term()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def fence_pending(scope) when scope == :all or is_list(scope) do
    scope = normalize_destinations(scope)

    transaction_read(fn ->
      groups = Memento.Query.all(NativeOutputGroup)
      {fenced, remaining} = Enum.split_with(groups, &destination_scope_matches?(&1, scope))
      Enum.each(fenced, &Memento.Query.delete_record/1)

      control = read_control(:write)

      _ =
        Memento.Query.write(%{
          control
          | pending_groups: length(remaining),
            pending_bytes: Enum.reduce(remaining, 0, &(&1.bytes + &2))
        })

      {:ok, length(fenced)}
    end)
  rescue
    error -> {:error, {:output_fence_failed, Exception.message(error)}}
  end

  def fence_pending(_scope), do: {:error, :invalid_output_scope}

  defp drain_group(group, drain_fun) when is_function(drain_fun, 1) do
    Enum.reduce_while(group.intents, :ok, fn intent, :ok ->
      case safe_drain(drain_fun, intent) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp drain_group(_group, _drain_fun), do: {:error, :invalid_drain_fun}

  defp drain_result(group, drain_fun, true, options) do
    with :ok <- await_output_turn(group.sequence, group.destinations, options),
         :ok <- with_draining_sequence(group.sequence, fn -> drain_group(group, drain_fun) end) do
      :ok
    end
  end

  defp drain_result(group, drain_fun, _persisted?, _options), do: drain_group(group, drain_fun)

  defp await_output_turn(sequence, destinations, options) when is_integer(sequence) and sequence > 0 do
    timeout_ms = max(Keyword.get(options, :output_order_timeout_ms, 15_000), 1)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    await_output_turn(
      sequence,
      normalize_destinations(destinations),
      deadline,
      10,
      Process.get(@draining_sequences_key, [])
    )
  end

  defp await_output_turn(_sequence, _destinations, _options), do: {:error, :invalid_output_sequence}

  defp await_output_turn(sequence, destinations, deadline, sleep_ms, draining_sequences) do
    now = System.monotonic_time(:millisecond)
    active_sequence = List.first(draining_sequences)

    case first_pending_sequence(destinations) do
      ^sequence ->
        :ok

      first when is_integer(first) and first == active_sequence and sequence > first ->
        :ok

      nil ->
        {:error, :output_group_missing}

      first when first > sequence ->
        {:error, :stale_output_group}

      _first ->
        if now >= deadline do
          {:error, :output_order_timeout}
        else
          Process.sleep(min(sleep_ms, max(deadline - now, 1)))
          await_output_turn(sequence, destinations, deadline, sleep_ms, draining_sequences)
        end
    end
  end

  defp with_draining_sequence(sequence, fun) when is_integer(sequence) and is_function(fun, 0) do
    previous = Process.get(@draining_sequences_key, [])
    Process.put(@draining_sequences_key, [sequence | previous])

    try do
      fun.()
    after
      case previous do
        [] -> Process.delete(@draining_sequences_key)
        _ -> Process.put(@draining_sequences_key, previous)
      end
    end
  end

  defp first_pending_sequence(destinations) do
    transaction_read(fn ->
      NativeOutputGroup
      |> Memento.Query.all()
      |> Enum.filter(&destination_scope_matches?(&1, destinations))
      |> Enum.map(& &1.id)
      |> Enum.min(fn -> nil end)
    end)
  rescue
    _ -> nil
  end

  defp safe_drain(drain_fun, intent) do
    case drain_fun.(intent) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_drain_result, other}}
    end
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_effect_drain(drain_fun, intent) do
    case drain_fun.(intent) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_effect_drain_result, other}}
    end
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_drain_error(fun, group, reason) when is_function(fun, 2) do
    fun.(group, reason)
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_drain_error(_fun, _group, _reason), do: :ok

  @doc "Adds one output intent to the active transaction attempt."
  @spec collect_intent(map()) :: :ok | {:error, term()} | :inactive
  def collect_intent(intent) when is_map(intent) do
    case Process.get(@attempt_key) do
      nil ->
        :inactive

      attempt ->
        case collect(attempt, intent) do
          {:ok, next} ->
            Process.put(@attempt_key, next)
            :ok

          {:error, _} = error ->
            Process.put({@attempt_key, :error}, error)
            error
        end
    end
  end

  def collect_intent(_intent), do: {:error, :invalid_output_intent}

  @doc "Drains a committed native-network publication intent."
  @spec drain_publication(map()) :: :ok | {:error, term()}
  def drain_publication(intent), do: ElixIRCd.Server.S2S.Publication.drain(intent)

  @doc "Drains a list of external effects and reports the first failed effect."
  @spec drain_effects([map()], (map() -> term())) :: :ok | {:error, term()}
  def drain_effects(intents, drain_fun) when is_list(intents) and is_function(drain_fun, 1) do
    Enum.reduce_while(intents, :ok, fn intent, :ok ->
      case safe_effect_drain(drain_fun, intent) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def drain_effects(_intents, _drain_fun), do: {:error, :invalid_effect_drain}

  @doc "Reports whether this process is currently collecting transaction effects."
  @spec collecting?() :: boolean()
  def collecting?, do: is_map(Process.get(@attempt_key))

  @doc "Allocates the next durable local logical stamp."
  @spec next_stamp(String.t(), Identity.id()) :: Identity.stamp()
  def next_stamp(sid, boot) when is_binary(sid) and is_binary(boot) do
    transaction_read(fn -> allocate_stamp(sid, boot) end)
  end

  @doc "Advances the durable local logical clock after accepting a stamped row."
  @spec observe_stamp(Identity.stamp()) :: :ok
  def observe_stamp([counter, _sid, _boot] = stamp) when is_integer(counter) and counter >= 0 do
    observe_stamps([stamp])
  end

  def observe_stamp(_stamp), do: :ok

  @doc "Advances the durable local logical clock once for a batch of accepted stamps."
  @spec observe_stamps([Identity.stamp()]) :: :ok
  def observe_stamps(stamps) when is_list(stamps) do
    counters = for [counter, _sid, _boot] <- stamps, is_integer(counter) and counter >= 0, do: counter

    if counters == [] do
      :ok
    else
      transaction_read(fn -> observe_counter(Enum.max(counters)) end)
    end
  end

  defp committed_transaction(fun, generation, attempt_options, output, persist?, options, mode \\ :bang) do
    transaction_fun = fn ->
      Process.put(@attempt_key, attempt(generation, attempt_options))
      Process.delete({@attempt_key, :error})
      result = fun.()
      attempt = Process.get(@attempt_key)

      case Process.get({@attempt_key, :error}) do
        nil ->
          case attempt do
            %{intents: []} ->
              {result, attempt, nil}

            %{} ->
              case commit_attempt(output, attempt, generation, persist?, options) do
                {:ok, group} -> {result, attempt, group}
                {:error, reason} -> Memento.Transaction.abort({:output_capacity, reason})
              end
          end

        error ->
          Memento.Transaction.abort({:output_capacity, error})
      end
    end

    case mode do
      :safe -> Memento.transaction(transaction_fun)
      :bang -> Memento.transaction!(transaction_fun)
    end
  end

  defp pending_group(sequence) when is_integer(sequence) and sequence > 0 do
    transaction_read(fn ->
      case Memento.Query.read(NativeOutputGroup, sequence, lock: :read) do
        %NativeOutputGroup{} = record -> group_from_record(record)
        nil -> nil
      end
    end)
  rescue
    _ -> nil
  end

  defp pending_group(_sequence), do: nil

  defp matching_pending_group?(_group, nil), do: :ok

  defp matching_pending_group?(
         %{sequence: sequence, generation: generation},
         %{sequence: sequence, generation: generation}
       ),
       do: :ok

  defp matching_pending_group?(_group, _expected), do: {:error, :stale_output_group}

  defp commit_attempt(output, attempt, generation, true, options) do
    if Keyword.get(options, :deferred, false) and sensitive_attempt?(attempt) do
      {:error, :sensitive_output_not_deferred}
    else
      if Memento.Transaction.inside?() do
        persist_attempt(attempt, generation, options)
      else
        case commit(output, attempt, generation) do
          {:ok, _next, group} -> {:ok, group}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp commit_attempt(output, attempt, generation, false, _options) do
    case commit(output, attempt, generation) do
      {:ok, _next, group} -> {:ok, group}
      {:error, _} = error -> error
    end
  end

  defp persist_attempt(attempt, generation, options) do
    attempt = persistable_attempt(attempt)

    if attempt.intents == [] do
      {:ok, nil}
    else
      persist_attempt_record(attempt, generation, options)
    end
  end

  defp persist_attempt_record(attempt, generation, options) do
    control = read_control(:write)
    max_groups = Keyword.get(options, :max_groups, 65_536)
    max_bytes = Keyword.get(options, :aggregate_max_bytes, 128 * 1_048_576)

    cond do
      control.pending_groups >= max_groups ->
        {:error, :output_group_capacity}

      control.pending_bytes + attempt.bytes > max_bytes ->
        {:error, :output_bytes}

      true ->
        sequence = control.sequence + 1

        if sequence > Identity.max_uint() do
          {:error, :output_sequence_exhausted}
        else
          record =
            NativeOutputGroup.new(
              id: sequence,
              generation: generation,
              intents: Enum.reverse(attempt.intents),
              bytes: attempt.bytes,
              destinations: destinations_for_intents(Enum.reverse(attempt.intents))
            )

          _ = Memento.Query.write(record)

          _ =
            Memento.Query.write(%{
              control
              | sequence: sequence,
                pending_groups: control.pending_groups + 1,
                pending_bytes: control.pending_bytes + attempt.bytes
            })

          {:ok, group_from_record(record)}
        end
    end
  end

  defp sensitive_attempt?(%{intents: intents}), do: Enum.any?(intents, &sensitive_intent?/1)

  defp sensitive_intent?(intent) when is_map(intent),
    do: intent[:sensitive] == true or intent["sensitive"] == true

  defp sensitive_intent?(_intent), do: false

  defp persistable_attempt(%{intents: intents} = attempt) do
    intents = Enum.reject(intents, &sensitive_intent?/1)

    %{
      attempt
      | intents: intents,
        count: length(intents),
        bytes: Enum.reduce(intents, 0, fn intent, bytes -> bytes + intent_budget_bytes(intent) end)
    }
  end

  defp drain_group_for_attempt(output, attempt, generation, committed_group) do
    sequence = if is_map(committed_group), do: committed_group.sequence, else: output.next_sequence

    %{
      sequence: sequence,
      generation: generation,
      intents: Enum.reverse(attempt.intents),
      bytes: attempt.bytes,
      destinations: destinations_for_intents(Enum.reverse(attempt.intents))
    }
  end

  defp pure_group(output, attempt, generation) do
    case commit(output, attempt, generation) do
      {:ok, _next, group} -> group
      {:error, reason} -> raise ArgumentError, "output commit failed: #{inspect(reason)}"
    end
  end

  defp acknowledge_persisted(sequence) do
    result =
      transaction_read(fn ->
        case Memento.Query.read(NativeOutputGroup, sequence, lock: :write) do
          %NativeOutputGroup{bytes: bytes} = group ->
            _ = Memento.Query.delete_record(group)
            control = read_control(:write)

            if control.pending_groups > 0 and control.pending_bytes >= bytes do
              _ =
                Memento.Query.write(%{
                  control
                  | pending_groups: control.pending_groups - 1,
                    pending_bytes: control.pending_bytes - bytes
                })

              :ok
            else
              Memento.Transaction.abort(:output_control_corrupt)
            end

          nil ->
            {:error, :output_group_missing}
        end
      end)

    case result do
      :ok -> :ok
      {:error, _} = error -> error
      other -> other
    end
  rescue
    error -> {:error, {:output_ack_failed, Exception.message(error)}}
  end

  defp group_from_record(%NativeOutputGroup{
         id: sequence,
         generation: generation,
         intents: intents,
         bytes: bytes,
         destinations: destinations
       }) do
    %{
      sequence: sequence,
      generation: generation,
      intents: intents,
      bytes: bytes,
      destinations: normalize_destinations(destinations)
    }
  end

  defp destinations_for_intents(intents) when is_list(intents) do
    destinations = intents |> Enum.flat_map(&intent_destinations/1) |> Enum.uniq()
    if destinations == [], do: [:global], else: destinations
  end

  defp intent_destinations(%{kind: kind} = intent) do
    case kind do
      :c2s_message ->
        c2s_destination(intent[:recipient])

      :c2s_disconnect ->
        c2s_destination(intent)

      :connection_cleanup ->
        c2s_destination(intent)

      :s2s_request ->
        s2s_target_destination(intent[:target_sid])

      :s2s_request_sequence ->
        s2s_target_destination(intent[:target_sid])

      :s2s_sasl_request ->
        s2s_target_destination(intent[:target_sid])

      :s2s_sasl_cancel ->
        s2s_target_destination(intent[:target_sid] || intent[:authority_sid])

      kind
      when kind in [
             :s2s_rows,
             :s2s_user_put,
             :s2s_user_quit,
             :s2s_memberships,
             :s2s_channel,
             :s2s_channel_list,
             :s2s_member_status,
             :s2s_policy_changed
           ] ->
        [:s2s_all]

      :job_enqueue ->
        [:external]

      _ ->
        [:global]
    end
  end

  defp intent_destinations(%{"kind" => kind} = intent) do
    intent
    |> Map.put(:kind, kind)
    |> intent_destinations()
  end

  defp intent_destinations(_intent), do: [:global]

  defp c2s_destination(%{uid: uid, connection_generation: generation})
       when is_binary(uid) and is_binary(generation),
       do: [{:c2s, uid, generation}]

  defp c2s_destination(%{"uid" => uid, "connection_generation" => generation})
       when is_binary(uid) and is_binary(generation),
       do: [{:c2s, uid, generation}]

  defp c2s_destination(_intent), do: [:global]

  defp s2s_target_destination(target_sid) when is_binary(target_sid), do: [{:s2s_target, target_sid}]
  defp s2s_target_destination(_target_sid), do: [:global]

  defp normalize_destinations(:all), do: [:global]

  defp normalize_destinations(destinations) when is_list(destinations) do
    destinations = Enum.uniq(destinations)
    if destinations == [], do: [:global], else: destinations
  end

  defp normalize_destinations(_destinations), do: [:global]

  defp destination_scope_matches?(%NativeOutputGroup{destinations: group_destinations}, scope),
    do: destination_lists_overlap?(normalize_destinations(group_destinations), scope)

  defp destination_scope_matches?(%{destinations: group_destinations}, scope),
    do: destination_lists_overlap?(normalize_destinations(group_destinations), scope)

  defp destination_lists_overlap?(group_destinations, scope) do
    :global in group_destinations or :global in scope or
      Enum.any?(group_destinations, fn group_destination ->
        Enum.any?(scope, &destinations_overlap?(group_destination, &1))
      end)
  end

  defp destinations_overlap?(:s2s_all, {:s2s_target, _target_sid}), do: true
  defp destinations_overlap?(:s2s_all, {:s2s_peer, _peer_sid}), do: true
  defp destinations_overlap?(:s2s_all, :s2s_all), do: true
  defp destinations_overlap?({:s2s_target, _target_sid}, :s2s_all), do: true
  defp destinations_overlap?({:s2s_peer, _peer_sid}, :s2s_all), do: true
  defp destinations_overlap?(left, right), do: left == right

  defp read_control(lock) do
    case Memento.Query.read(NativeOutputControl, @control_key, lock: lock) do
      %NativeOutputControl{} = control -> control
      nil -> Memento.Query.write(NativeOutputControl.new())
    end
  end

  defp allocate_stamp(sid, boot) do
    control = read_control(:write)
    next = control.logical_counter + 1

    if next > Identity.max_uint() do
      Memento.Transaction.abort(:logical_counter_exhausted)
    else
      _ = Memento.Query.write(%{control | logical_counter: next})
      [next, sid, boot]
    end
  end

  defp observe_counter(counter) do
    control = read_control(:write)

    if counter > control.logical_counter do
      _ = Memento.Query.write(%{control | logical_counter: counter})
    end

    :ok
  end

  defp transaction_read(fun) do
    if Memento.Transaction.inside?(), do: fun.(), else: Memento.transaction!(fun)
  end

  defp uncertain_drain(group, reason) do
    case Process.whereis(ElixIRCd.Server.S2S.Manager) do
      manager when is_pid(manager) -> send(manager, {:s2s_output_uncertain, group, reason})
      _ -> :ok
    end

    :ok
  end
end
