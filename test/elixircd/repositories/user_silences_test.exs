defmodule ElixIRCd.Repositories.UserSilencesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Repositories.UserSilences

  describe "create/1" do
    test "creates a new user silence entry" do
      user_pid = self()
      mask = "nick!user@host.com"

      Memento.transaction!(fn ->
        silence = UserSilences.create(%{user_pid: user_pid, mask: mask})

        assert silence.user_pid == user_pid
        assert silence.mask == mask
        assert %DateTime{} = silence.created_at
      end)
    end

    test "creates multiple silence entries for same user" do
      user_pid = self()
      mask1 = "nick1!user@host.com"
      mask2 = "nick2!user@host.com"

      Memento.transaction!(fn ->
        silence1 = UserSilences.create(%{user_pid: user_pid, mask: mask1})
        silence2 = UserSilences.create(%{user_pid: user_pid, mask: mask2})

        assert silence1.mask == mask1
        assert silence2.mask == mask2
        assert silence1.user_pid == silence2.user_pid
      end)
    end
  end

  describe "get_by_user_pid/1" do
    test "returns empty list when no silence entries exist" do
      user_pid = self()

      Memento.transaction!(fn ->
        silence_entries = UserSilences.get_by_user_pid(user_pid)
        assert silence_entries == []
      end)
    end

    test "returns list of silence entries for user" do
      user_pid = self()
      mask1 = "nick1!user@host.com"
      mask2 = "nick2!user@host.com"

      Memento.transaction!(fn ->
        UserSilences.create(%{user_pid: user_pid, mask: mask1})
        UserSilences.create(%{user_pid: user_pid, mask: mask2})

        silence_entries = UserSilences.get_by_user_pid(user_pid)
        assert length(silence_entries) == 2
        silence_masks = Enum.map(silence_entries, & &1.mask)
        assert mask1 in silence_masks
        assert mask2 in silence_masks
      end)
    end

    test "returns only entries for specific user" do
      user_pid1 = self()
      user_pid2 = spawn(fn -> :ok end)
      mask1 = "nick1!user@host.com"
      mask2 = "nick2!user@host.com"

      Memento.transaction!(fn ->
        UserSilences.create(%{user_pid: user_pid1, mask: mask1})
        UserSilences.create(%{user_pid: user_pid2, mask: mask2})

        silence_entries = UserSilences.get_by_user_pid(user_pid1)
        assert length(silence_entries) == 1
        silence_masks = Enum.map(silence_entries, & &1.mask)
        assert mask1 in silence_masks
        assert mask2 not in silence_masks
      end)
    end
  end

  describe "get_by_user_pid_and_mask/2" do
    test "returns error when silence entry not found" do
      user_pid = self()
      mask = "nick!user@host.com"

      Memento.transaction!(fn ->
        result = UserSilences.get_by_user_pid_and_mask(user_pid, mask)
        assert result == {:error, :user_silence_not_found}
      end)
    end

    test "returns silence entry when found" do
      user_pid = self()
      mask = "nick!user@host.com"

      Memento.transaction!(fn ->
        created_silence = UserSilences.create(%{user_pid: user_pid, mask: mask})

        result = UserSilences.get_by_user_pid_and_mask(user_pid, mask)
        assert {:ok, found_silence} = result
        assert found_silence.user_pid == created_silence.user_pid
        assert found_silence.mask == created_silence.mask
      end)
    end

    test "returns error when user_pid matches but mask doesn't" do
      user_pid = self()
      mask1 = "nick1!user@host.com"
      mask2 = "nick2!user@host.com"

      Memento.transaction!(fn ->
        UserSilences.create(%{user_pid: user_pid, mask: mask1})

        result = UserSilences.get_by_user_pid_and_mask(user_pid, mask2)
        assert result == {:error, :user_silence_not_found}
      end)
    end
  end

  describe "delete/1" do
    test "deletes a silence entry" do
      user_pid = self()
      mask = "nick!user@host.com"

      Memento.transaction!(fn ->
        silence = UserSilences.create(%{user_pid: user_pid, mask: mask})
        assert UserSilences.get_by_user_pid(user_pid) != []

        UserSilences.delete(silence)
        assert Enum.empty?(UserSilences.get_by_user_pid(user_pid))
      end)
    end

    test "deletes only the specified silence entry" do
      user_pid = self()
      mask1 = "nick1!user@host.com"
      mask2 = "nick2!user@host.com"

      Memento.transaction!(fn ->
        silence1 = UserSilences.create(%{user_pid: user_pid, mask: mask1})
        UserSilences.create(%{user_pid: user_pid, mask: mask2})
        assert length(UserSilences.get_by_user_pid(user_pid)) == 2

        UserSilences.delete(silence1)
        silence_entries = UserSilences.get_by_user_pid(user_pid)
        assert length(silence_entries) == 1
        silence_masks = Enum.map(silence_entries, & &1.mask)
        assert mask1 not in silence_masks
        assert mask2 in silence_masks
      end)
    end
  end

  describe "delete_by_user_pid/1" do
    test "deletes all silence entries for a user" do
      user_pid = self()
      mask1 = "nick1!user@host.com"
      mask2 = "nick2!user@host.com"

      Memento.transaction!(fn ->
        UserSilences.create(%{user_pid: user_pid, mask: mask1})
        UserSilences.create(%{user_pid: user_pid, mask: mask2})
        assert length(UserSilences.get_by_user_pid(user_pid)) == 2

        UserSilences.delete_by_user_pid(user_pid)
        assert Enum.empty?(UserSilences.get_by_user_pid(user_pid))
      end)
    end

    test "deletes only entries for specified user" do
      user_pid1 = self()
      user_pid2 = spawn(fn -> :ok end)
      mask1 = "nick1!user@host.com"
      mask2 = "nick2!user@host.com"

      Memento.transaction!(fn ->
        UserSilences.create(%{user_pid: user_pid1, mask: mask1})
        UserSilences.create(%{user_pid: user_pid2, mask: mask2})
        assert length(UserSilences.get_by_user_pid(user_pid1)) == 1
        assert length(UserSilences.get_by_user_pid(user_pid2)) == 1

        UserSilences.delete_by_user_pid(user_pid1)
        assert Enum.empty?(UserSilences.get_by_user_pid(user_pid1))
        assert length(UserSilences.get_by_user_pid(user_pid2)) == 1
      end)
    end

    test "does nothing when no silence entries exist" do
      user_pid = self()

      Memento.transaction!(fn ->
        assert Enum.empty?(UserSilences.get_by_user_pid(user_pid))

        UserSilences.delete_by_user_pid(user_pid)
        assert Enum.empty?(UserSilences.get_by_user_pid(user_pid))
      end)
    end
  end
end
