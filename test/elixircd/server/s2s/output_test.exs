defmodule ElixIRCd.Server.S2S.OutputTest do
  use ExUnit.Case, async: false

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Tables.NativeOutputControl

  test "aborted or retried attempts do not publish intents" do
    generation = Identity.nonce()
    output = Output.new(generation, max_bytes: 1_024)
    attempt = Output.attempt(generation)
    {:ok, attempt} = Output.collect(attempt, %{kind: :c2s, uid: Identity.uid()})

    assert {:ok, output, group} = Output.commit(output, attempt, generation)
    assert {:ok, ^group} = Output.peek(output, generation)
    assert {:error, :stale_output_attempt} = Output.commit(output, attempt, Identity.nonce())
    assert {:ok, output} = Output.acknowledge(output, generation, group.sequence)
    assert :empty = Output.peek(output, generation)
  end

  test "queue accounting and generation fences are bounded" do
    generation = Identity.nonce()
    output = Output.new(generation, max_bytes: 1, max_groups: 1)
    attempt = Output.attempt(generation, max_bytes: 1)

    assert {:error, :output_attempt_bytes} = Output.collect(attempt, %{text: "too large"})
    assert {:error, :stale_output_generation} = Output.peek(output, Identity.nonce())

    fenced = Output.fence(output, Identity.nonce())
    assert Output.stats(fenced) == %{groups: 0, bytes: 0, next_sequence: 1}
  end

  test "allocates and observes durable logical stamps independently of wall time" do
    sid = "root"
    boot = Identity.boot()

    [first_counter, ^sid, ^boot] = first = Output.next_stamp(sid, boot)
    [second_counter, ^sid, ^boot] = Output.next_stamp(sid, boot)
    assert second_counter == first_counter + 1

    observed = second_counter + 40
    assert :ok = Output.observe_stamp([observed, "peer", Identity.boot()])
    assert [next_counter, ^sid, ^boot] = Output.next_stamp(sid, boot)
    assert next_counter == observed + 1
    assert first != [second_counter, sid, boot]
  end

  test "transaction drains collected effects only after the commit" do
    test_pid = self()

    assert :ok =
             Output.transaction(
               fn ->
                 assert :ok = Output.collect_intent(%{kind: :marker, value: 1})
                 :ok
               end,
               drain_fun: fn intent ->
                 send(test_pid, {:drained, intent})
                 :ok
               end,
               persist: false
             )

    assert_receive {:drained, %{kind: :marker, value: 1}}
  end

  test "serializes concurrent committed groups by their persistent sequence" do
    parent = self()

    first =
      Task.async(fn ->
        Output.transaction(
          fn ->
            assert :ok = Output.collect_intent(%{kind: :ordered, value: 1})
            :first
          end,
          drain_fun: fn intent ->
            send(parent, {:draining, intent})

            receive do
              :release_first -> :ok
            end
          end,
          output_order_timeout_ms: 2_000
        )
      end)

    assert_receive {:draining, %{kind: :ordered, value: 1}}, 1_000

    second =
      Task.async(fn ->
        Output.transaction(
          fn ->
            assert :ok = Output.collect_intent(%{kind: :ordered, value: 2})
            :second
          end,
          drain_fun: fn intent ->
            send(parent, {:draining, intent})
            :ok
          end,
          output_order_timeout_ms: 2_000
        )
      end)

    refute_receive {:draining, %{kind: :ordered, value: 2}}, 100
    send(first.pid, :release_first)
    assert Task.await(first, 2_000) == :first
    assert_receive {:draining, %{kind: :ordered, value: 2}}, 1_000
    assert Task.await(second, 2_000) == :second
  end

  test "records immutable destination scopes for local and routed intents" do
    assert {:ok, _} = Output.fence_pending()

    assert {:ok, :local, local_group} =
             Output.transaction_deferred(fn ->
               assert :ok =
                        Output.collect_intent(%{
                          kind: :c2s_message,
                          recipient: %{uid: "local-uid", connection_generation: "generation-1"}
                        })

               :local
             end)

    assert local_group.destinations == [{:c2s, "local-uid", "generation-1"}]

    assert {:ok, :remote, remote_group} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :s2s_request, target_sid: "leaf"})
               :remote
             end)

    assert remote_group.destinations == [{:s2s_target, "leaf"}]
    assert {:ok, 2} = Output.fence_pending()
  end

  test "allows independent destination groups to drain concurrently" do
    assert {:ok, _} = Output.fence_pending()

    parent = self()

    assert {:ok, :alpha, alpha} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :s2s_request, target_sid: "alpha"})
               :alpha
             end)

    assert {:ok, :beta, beta} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :s2s_request, target_sid: "beta"})
               :beta
             end)

    first =
      Task.async(fn ->
        Output.drain_pending(alpha, fn _intent ->
          send(parent, {:draining, :alpha})

          receive do
            :release_alpha -> :ok
          end
        end)
      end)

    assert_receive {:draining, :alpha}, 1_000

    second =
      Task.async(fn ->
        Output.drain_pending(beta, fn _intent ->
          send(parent, {:draining, :beta})
          :ok
        end)
      end)

    assert_receive {:draining, :beta}, 1_000
    assert Task.await(second, 2_000) == :ok
    send(first.pid, :release_alpha)
    assert Task.await(first, 2_000) == :ok
    assert [] = Output.pending_groups()
  end

  test "fences only the groups that share an uncertain destination" do
    assert {:ok, _} = Output.fence_pending()

    assert {:ok, :alpha, alpha} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :s2s_request, target_sid: "alpha"})
               :alpha
             end)

    assert {:ok, :beta, beta} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :s2s_request, target_sid: "beta"})
               :beta
             end)

    assert {:ok, 1} = Output.fence_pending([{:s2s_target, "alpha"}])
    assert [%{sequence: beta_sequence}] = Output.pending_groups()
    assert beta_sequence == beta.sequence
    assert :ok = Output.drain_pending(beta, fn _intent -> :ok end)
    assert [] = Output.pending_groups()
    refute alpha.sequence == beta_sequence
  end

  test "a transaction without effects does not create an empty committed group" do
    before = Output.pending_groups()
    assert :unchanged = Output.transaction(fn -> :unchanged end)
    assert Output.pending_groups() == before
  end

  test "an aborted transaction drains no intent" do
    test_pid = self()

    try do
      Output.transaction(
        fn ->
          assert :ok = Output.collect_intent(%{kind: :marker, value: 2})
          Memento.Transaction.abort(:forced_output_abort)
        end,
        drain_fun: fn intent ->
          send(test_pid, {:drained, intent})
          :ok
        end,
        persist: false
      )
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end

    refute_receive {:drained, %{kind: :marker, value: 2}}
  end

  test "a retried Mnesia transaction drains only the committed attempt" do
    parent = self()
    attempts = :counters.new(1, [])
    first_key = "retry-a-" <> Identity.nonce()
    second_key = "retry-b-" <> Identity.nonce()

    Memento.transaction!(fn ->
      Memento.Query.write(NativeOutputControl.new(id: first_key))
      Memento.Query.write(NativeOutputControl.new(id: second_key))
    end)

    on_exit(fn ->
      Memento.transaction(fn ->
        Memento.Query.delete(NativeOutputControl, first_key)
        Memento.Query.delete(NativeOutputControl, second_key)
      end)
    end)

    competitor =
      Task.async(fn ->
        Memento.Transaction.execute(
          fn ->
            assert %NativeOutputControl{} = Memento.Query.read(NativeOutputControl, second_key, lock: :write)
            send(parent, {:competitor_locked_second_key, self()})

            receive do
              {:output_locked_first_key, output_pid} ->
                send(output_pid, :competitor_waiting_for_first_key)
                Process.sleep(25)
            end

            assert %NativeOutputControl{} = Memento.Query.read(NativeOutputControl, first_key, lock: :write)
            :competitor
          end,
          0
        )
      end)

    assert_receive {:competitor_locked_second_key, competitor_pid}, 1_000

    output =
      Task.async(fn ->
        Output.transaction(
          fn ->
            :counters.add(attempts, 1, 1)
            attempt = :counters.get(attempts, 1)
            assert %NativeOutputControl{} = Memento.Query.read(NativeOutputControl, first_key, lock: :write)

            assert :ok =
                     Output.collect_intent(%{
                       kind: :retry_marker,
                       value: if(attempt == 1, do: :aborted_attempt, else: :committed_attempt)
                     })

            if attempt == 1 do
              send(competitor_pid, {:output_locked_first_key, self()})

              receive do
                :competitor_waiting_for_first_key -> :ok
              end
            end

            assert %NativeOutputControl{} = Memento.Query.read(NativeOutputControl, second_key, lock: :write)
            :accepted
          end,
          drain_fun: fn intent ->
            send(parent, {:retry_drained, intent})
            :ok
          end
        )
      end)

    assert :accepted = Task.await(output, 5_000)
    assert {:ok, :competitor} = Task.await(competitor, 5_000)
    assert :counters.get(attempts, 1) >= 2
    assert_receive {:retry_drained, %{kind: :retry_marker, value: :committed_attempt}}, 1_000
    refute_receive {:retry_drained, %{kind: :retry_marker, value: :aborted_attempt}}
  end

  test "collector capacity aborts the transaction before effects can drain" do
    test_pid = self()

    result =
      try do
        Output.transaction(
          fn ->
            assert {:error, :output_attempt_bytes} =
                     Output.collect_intent(%{kind: :marker, value: String.duplicate("x", 128)})

            :ok
          end,
          max_bytes: 1,
          drain_fun: fn intent ->
            send(test_pid, {:drained, intent})
            :ok
          end,
          persist: false
        )
      catch
        _kind, reason -> {:aborted, reason}
      end

    assert match?({:aborted, _}, result)
    refute_receive {:drained, _}
  end

  test "a drain failure is reported after commit and invokes the failure hook" do
    test_pid = self()

    result =
      Output.transaction(
        fn ->
          assert :ok = Output.collect_intent(%{kind: :marker, value: 3})
          :committed
        end,
        drain_fun: fn %{kind: :marker} -> {:error, :writer_lost} end,
        on_drain_error: fn group, reason -> send(test_pid, {:drain_failed, group.sequence, reason}) end,
        persist: false
      )

    assert {:error, {:output_drain_failed, :writer_lost}} = result
    assert_receive {:drain_failed, 1, :writer_lost}
  end

  test "a crashing drain is fenced as an uncertain output" do
    result =
      Output.transaction(
        fn ->
          assert :ok = Output.collect_intent(%{kind: :marker, value: 4})
          :committed
        end,
        drain_fun: fn _intent -> raise "writer crashed" end,
        persist: false
      )

    assert {:error, {:output_drain_failed, {:exception, RuntimeError, "writer crashed"}}} = result
  end

  test "persists a committed group until the drain succeeds and fences failed groups" do
    assert {:error, {:output_drain_failed, :writer_lost}} =
             Output.transaction(
               fn ->
                 assert :ok = Output.collect_intent(%{kind: :marker, value: 5})
                 :committed
               end,
               drain_fun: fn _intent -> {:error, :writer_lost} end
             )

    assert [%{intents: [%{kind: :marker, value: 5}]}] = Output.pending_groups()
    assert {:ok, 1} = Output.fence_pending()
    assert [] = Output.pending_groups()
  end

  test "keeps sensitive intents out of the persistent outbox while draining after commit" do
    secret = "plain-credential"
    test_pid = self()

    assert :committed =
             Output.transaction(
               fn ->
                 assert :ok = Output.collect_intent(%{kind: :safe_marker, value: 9})

                 assert :ok =
                          Output.collect_intent(%{
                            kind: :s2s_sasl_request,
                            sensitive: true,
                            args: %{"data" => secret}
                          })

                 :committed
               end,
               drain_fun: fn intent ->
                 send(test_pid, {:drained_sensitive_test, intent})
                 :ok
               end
             )

    assert_receive {:drained_sensitive_test, %{kind: :safe_marker, value: 9}}
    assert_receive {:drained_sensitive_test, %{kind: :s2s_sasl_request, args: %{"data" => ^secret}}}

    refute Enum.any?(Output.pending_groups(), fn group ->
             Enum.any?(group.intents, &(&1[:sensitive] == true or get_in(&1, [:args, "data"]) == secret))
           end)
  end

  test "rejects sensitive intents from deferred output" do
    assert {:error, :sensitive_output_not_deferred} =
             Output.transaction_deferred(fn ->
               assert :ok =
                        Output.collect_intent(%{
                          kind: :s2s_sasl_request,
                          sensitive: true,
                          args: %{"data" => "credential"}
                        })

               :committed
             end)

    refute Enum.any?(Output.pending_groups(), fn group ->
             Enum.any?(group.intents, &(&1[:sensitive] == true))
           end)
  end

  test "reports failures from a strict effect drain" do
    assert {:error, :writer_lost} =
             Output.drain_effects([%{kind: :marker}], fn _intent -> {:error, :writer_lost} end)

    assert {:error, {:invalid_effect_drain_result, :queued}} =
             Output.drain_effects([%{kind: :marker}], fn _intent -> :queued end)
  end

  test "does not acknowledge a persisted group when its drain result is not explicit success" do
    assert {:ok, :committed, group} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :marker, value: 10})
               :committed
             end)

    assert {:error, {:invalid_drain_result, :queued}} =
             Output.drain_pending(group, fn _intent -> :queued end)

    assert Enum.any?(Output.pending_groups(), &(&1.sequence == group.sequence))
    assert {:ok, 1} = Output.fence_pending()
  end

  test "acknowledges a persisted group after a successful drain" do
    assert :committed =
             Output.transaction(
               fn ->
                 assert :ok = Output.collect_intent(%{kind: :marker, value: 6})
                 :committed
               end,
               drain_fun: fn _intent -> :ok end
             )

    refute Enum.any?(Output.pending_groups(), &Enum.any?(&1.intents, fn intent -> intent[:value] == 6 end))
  end

  test "defers a committed group to a later owner drain" do
    test_pid = self()

    assert {:ok, :committed, group} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :marker, value: 7})
               :committed
             end)

    assert %{sequence: sequence} = group
    assert [%{sequence: ^sequence}] = Output.pending_groups()

    assert :ok =
             Output.drain_pending(group, fn intent ->
               send(test_pid, {:deferred_drained, intent})
               :ok
             end)

    assert_receive {:deferred_drained, %{kind: :marker, value: 7}}
    refute Enum.any?(Output.pending_groups(), &(&1.sequence == sequence))
  end

  test "keeps a deferred group when its owner drain fails" do
    assert {:ok, :committed, group} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :marker, value: 8})
               :committed
             end)

    assert {:error, :writer_lost} = Output.drain_pending(group, fn _intent -> {:error, :writer_lost} end)
    assert Enum.any?(Output.pending_groups(), &(&1.sequence == group.sequence))
    assert {:ok, 1} = Output.fence_pending()
  end
end
