defmodule ElixIRCd.Repositories.UserAcceptsTest do
  use ElixIRCd.DataCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Tables.UserAccept

  describe "create/1" do
    test "creates a new user accept entry" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user = insert(:user)

        attrs = %{
          user_pid: user.pid,
          accepted_user_pid: accepted_user.pid
        }

        result = UserAccepts.create(attrs)

        assert %UserAccept{} = result
        assert result.user_pid == user.pid
        assert result.accepted_user_pid == accepted_user.pid
        assert %DateTime{} = result.created_at
      end)
    end
  end

  describe "get_by_user_pid/1" do
    test "returns empty list when user has no accept entries" do
      Memento.transaction!(fn ->
        user = insert(:user)

        result = UserAccepts.get_by_user_pid(user.pid)

        assert result == []
      end)
    end

    test "returns all accept entries for a user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user1 = insert(:user)
        accepted_user2 = insert(:user)

        _accept1 = insert(:user_accept, user: user, accepted_user: accepted_user1)
        _accept2 = insert(:user_accept, user: user, accepted_user: accepted_user2)

        result = UserAccepts.get_by_user_pid(user.pid)

        assert length(result) == 2
        result_pids = Enum.map(result, & &1.accepted_user_pid) |> Enum.sort()
        expected_pids = [accepted_user1.pid, accepted_user2.pid] |> Enum.sort()
        assert result_pids == expected_pids
      end)
    end

    test "only returns entries for the specified user" do
      Memento.transaction!(fn ->
        user1 = insert(:user)
        user2 = insert(:user)
        accepted_user = insert(:user)

        insert(:user_accept, user: user1, accepted_user: accepted_user)
        insert(:user_accept, user: user2, accepted_user: accepted_user)

        result = UserAccepts.get_by_user_pid(user1.pid)

        assert length(result) == 1
        assert hd(result).user_pid == user1.pid
      end)
    end
  end

  describe "get_by_user_pid_and_accepted_user_pid/2" do
    test "returns nil when no matching entry exists" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user = insert(:user)

        result = UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user.pid)

        assert result == nil
      end)
    end

    test "returns the matching entry when it exists" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user = insert(:user)

        accept_entry = insert(:user_accept, user: user, accepted_user: accepted_user)

        result = UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user.pid)

        assert result.user_pid == accept_entry.user_pid
        assert result.accepted_user_pid == accept_entry.accepted_user_pid
        assert result.created_at == accept_entry.created_at
      end)
    end

    test "returns correct entry when multiple entries exist for same user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user1 = insert(:user)
        accepted_user2 = insert(:user)

        accept1 = insert(:user_accept, user: user, accepted_user: accepted_user1)
        accept2 = insert(:user_accept, user: user, accepted_user: accepted_user2)

        result1 = UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user1.pid)
        result2 = UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user2.pid)

        assert result1.accepted_user_pid == accepted_user1.pid
        assert result2.accepted_user_pid == accepted_user2.pid
        assert result1.created_at == accept1.created_at
        assert result2.created_at == accept2.created_at
      end)
    end
  end

  describe "delete/2" do
    test "deletes the specified accept entry" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user = insert(:user)

        insert(:user_accept, user: user, accepted_user: accepted_user)

        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user.pid) != nil
        assert :ok = UserAccepts.delete(user.pid, accepted_user.pid)
        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user.pid) == nil
      end)
    end

    test "returns :ok when trying to delete non-existent entry" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user = insert(:user)

        assert :ok = UserAccepts.delete(user.pid, accepted_user.pid)
      end)
    end

    test "only deletes the specified entry when multiple exist" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user1 = insert(:user)
        accepted_user2 = insert(:user)

        insert(:user_accept, user: user, accepted_user: accepted_user1)
        insert(:user_accept, user: user, accepted_user: accepted_user2)

        assert :ok = UserAccepts.delete(user.pid, accepted_user1.pid)
        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user1.pid) == nil
        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user2.pid) != nil
      end)
    end
  end

  describe "delete_by_user_pid/1" do
    test "deletes all accept entries for a user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user1 = insert(:user)
        accepted_user2 = insert(:user)

        insert(:user_accept, user: user, accepted_user: accepted_user1)
        insert(:user_accept, user: user, accepted_user: accepted_user2)

        assert length(UserAccepts.get_by_user_pid(user.pid)) == 2

        assert :ok = UserAccepts.delete_by_user_pid(user.pid)
        assert UserAccepts.get_by_user_pid(user.pid) == []
      end)
    end

    test "returns :ok when user has no accept entries" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = UserAccepts.delete_by_user_pid(user.pid)
      end)
    end

    test "only deletes entries for the specified user" do
      Memento.transaction!(fn ->
        user1 = insert(:user)
        user2 = insert(:user)
        accepted_user = insert(:user)

        insert(:user_accept, user: user1, accepted_user: accepted_user)
        insert(:user_accept, user: user2, accepted_user: accepted_user)

        assert :ok = UserAccepts.delete_by_user_pid(user1.pid)
        assert UserAccepts.get_by_user_pid(user1.pid) == []
        assert length(UserAccepts.get_by_user_pid(user2.pid)) == 1
      end)
    end
  end

  describe "delete_by_accepted_user_pid/1" do
    test "deletes all entries where user is accepted by others" do
      Memento.transaction!(fn ->
        user1 = insert(:user)
        user2 = insert(:user)
        accepted_user = insert(:user)

        insert(:user_accept, user: user1, accepted_user: accepted_user)
        insert(:user_accept, user: user2, accepted_user: accepted_user)

        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user1.pid, accepted_user.pid) != nil
        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user2.pid, accepted_user.pid) != nil

        assert :ok = UserAccepts.delete_by_accepted_user_pid(accepted_user.pid)

        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user1.pid, accepted_user.pid) == nil
        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user2.pid, accepted_user.pid) == nil
      end)
    end

    test "returns :ok when no entries exist for the accepted user" do
      Memento.transaction!(fn ->
        accepted_user = insert(:user)

        assert :ok = UserAccepts.delete_by_accepted_user_pid(accepted_user.pid)
      end)
    end

    test "only deletes entries for the specified accepted user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user1 = insert(:user)
        accepted_user2 = insert(:user)

        insert(:user_accept, user: user, accepted_user: accepted_user1)
        insert(:user_accept, user: user, accepted_user: accepted_user2)

        assert :ok = UserAccepts.delete_by_accepted_user_pid(accepted_user1.pid)

        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user1.pid) == nil
        assert UserAccepts.get_by_user_pid_and_accepted_user_pid(user.pid, accepted_user2.pid) != nil
      end)
    end
  end

  describe "integration tests" do
    test "complete workflow: create, read, update, delete" do
      Memento.transaction!(fn ->
        user = insert(:user)
        accepted_user1 = insert(:user)
        accepted_user2 = insert(:user)

        assert UserAccepts.get_by_user_pid(user.pid) == []

        accept1 = UserAccepts.create(%{user_pid: user.pid, accepted_user_pid: accepted_user1.pid})
        assert accept1.user_pid == user.pid
        assert accept1.accepted_user_pid == accepted_user1.pid

        accepts = UserAccepts.get_by_user_pid(user.pid)
        assert length(accepts) == 1
        assert hd(accepts).accepted_user_pid == accepted_user1.pid

        _accept2 = UserAccepts.create(%{user_pid: user.pid, accepted_user_pid: accepted_user2.pid})

        accepts = UserAccepts.get_by_user_pid(user.pid)
        assert length(accepts) == 2
        accepted_pids = Enum.map(accepts, & &1.accepted_user_pid) |> Enum.sort()
        expected_pids = [accepted_user1.pid, accepted_user2.pid] |> Enum.sort()
        assert accepted_pids == expected_pids

        UserAccepts.delete(user.pid, accepted_user1.pid)

        accepts = UserAccepts.get_by_user_pid(user.pid)
        assert length(accepts) == 1
        assert hd(accepts).accepted_user_pid == accepted_user2.pid

        UserAccepts.delete_by_user_pid(user.pid)

        assert UserAccepts.get_by_user_pid(user.pid) == []
      end)
    end
  end
end
