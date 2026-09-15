defmodule ElixIRCd.Repositories.MetricsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Metrics

  test "registered-user peak remains monotonic and rolls back with registration" do
    Memento.transaction!(fn -> Metrics.record_user_peak(3) end)
    Memento.transaction!(fn -> Metrics.record_user_peak(1) end)
    assert Metrics.get(:highest_users) == 3

    assert {:error, {:transaction_aborted, :cancelled}} =
             Memento.transaction(fn ->
               Metrics.record_user_peak(8)
               Memento.Transaction.abort(:cancelled)
             end)

    assert Metrics.get(:highest_users) == 3
    assert Metrics.get(:highest_connections) == 0
  end

  describe "get/1" do
    test "returns 0 for non-existent metric on database" do
      assert Metrics.get(:highest_connections) == 0
    end

    test "returns the value of the metric on the database" do
      insert(:metric, key: :highest_connections, amount: 10)
      assert Metrics.get(:highest_connections) == 10
    end
  end

  describe "update_counter/2" do
    test "creates the metric on the database if it doesn't exist" do
      assert Metrics.update_counter(:highest_connections, 10) == 10
      assert Metrics.get(:highest_connections) == 10
    end

    test "updates the metric on the database if it exists" do
      insert(:metric, key: :highest_connections, amount: 10)

      assert Metrics.update_counter(:highest_connections, 20) == 30
      assert Metrics.get(:highest_connections) == 30
    end
  end
end
