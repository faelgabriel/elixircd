defmodule ElixIRCd.Repositories.UserMonitorsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.UserMonitors

  describe "create/1" do
    test "creates a user monitor entry" do
      Memento.transaction!(fn ->
        user = insert(:user)
        monitor = UserMonitors.create(%{user_pid: user.pid, target_nick_key: "target"})

        assert monitor.user_pid == user.pid
        assert monitor.target_nick_key == "target"
      end)
    end
  end

  describe "get_by_user_pid/1" do
    test "returns monitors for a user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:user_monitor, user: user, target_nick_key: "target1")
        insert(:user_monitor, user: user, target_nick_key: "target2")

        monitors = UserMonitors.get_by_user_pid(user.pid)
        assert length(monitors) == 2
        assert Enum.any?(monitors, &(&1.target_nick_key == "target1"))
        assert Enum.any?(monitors, &(&1.target_nick_key == "target2"))
      end)
    end
  end

  describe "get_by_target_nick_key/1" do
    test "returns monitors for a target" do
      Memento.transaction!(fn ->
        user1 = insert(:user)
        user2 = insert(:user)
        insert(:user_monitor, user: user1, target_nick_key: "target")
        insert(:user_monitor, user: user2, target_nick_key: "target")

        monitors = UserMonitors.get_by_target_nick_key("target")
        assert length(monitors) == 2
        assert Enum.any?(monitors, &(&1.user_pid == user1.pid))
        assert Enum.any?(monitors, &(&1.user_pid == user2.pid))
      end)
    end
  end

  describe "exists?/2" do
    test "returns true if monitor exists" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:user_monitor, user: user, target_nick_key: "target")

        assert UserMonitors.exists?(user.pid, "target")
      end)
    end

    test "returns false if monitor does not exist" do
      Memento.transaction!(fn ->
        user = insert(:user)
        refute UserMonitors.exists?(user.pid, "target")
      end)
    end
  end

  describe "delete/2" do
    test "deletes a monitor entry" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:user_monitor, user: user, target_nick_key: "target")

        assert UserMonitors.exists?(user.pid, "target")
        UserMonitors.delete(user.pid, "target")
        refute UserMonitors.exists?(user.pid, "target")
      end)
    end
  end

  describe "factory coverage" do
    test "insert(:user_monitor) creates a user if not provided" do
      Memento.transaction!(fn ->
        monitor = insert(:user_monitor)
        assert monitor.user_pid != nil
        assert monitor.target_nick_key != nil
      end)
    end
  end
end
