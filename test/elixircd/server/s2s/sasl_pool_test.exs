defmodule ElixIRCd.Server.S2S.SASL.PoolTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.SASL.Pool

  test "rejects work while its fixed worker set is occupied" do
    parent = self()
    {:ok, pool} = Pool.start_link(max_workers: 1)
    on_exit(fn -> if Process.alive?(pool), do: Pool.stop(pool) end)

    assert {:ok, job_ref} =
             Pool.submit(pool, parent, fn ->
               Process.sleep(100)
               :verified
             end)

    assert :busy = Pool.submit(pool, parent, fn -> :unexpected end)
    assert_receive {:s2s_sasl_result, ^job_ref, {:ok, :verified}}, 1_000

    assert {:ok, next_ref} = Pool.submit(pool, parent, fn -> :next end)
    assert_receive {:s2s_sasl_result, ^next_ref, {:ok, :next}}, 1_000
  end

  test "cancels a running job and makes a replacement worker available" do
    parent = self()
    {:ok, pool} = Pool.start_link(max_workers: 1)
    on_exit(fn -> if Process.alive?(pool), do: Pool.stop(pool) end)

    assert {:ok, cancelled_ref} =
             Pool.submit(pool, parent, fn ->
               Process.sleep(5_000)
               :must_not_complete
             end)

    assert :ok = Pool.cancel(pool, cancelled_ref)

    next_ref =
      Enum.find_value(1..50, fn _attempt ->
        case Pool.submit(pool, parent, fn -> :next_after_cancel end) do
          {:ok, ref} ->
            ref

          :busy ->
            Process.sleep(10)
            nil
        end
      end)

    assert is_reference(next_ref)
    assert_receive {:s2s_sasl_result, ^next_ref, {:ok, :next_after_cancel}}, 1_000
    refute_receive {:s2s_sasl_result, ^cancelled_ref, _result}, 100
  end
end
