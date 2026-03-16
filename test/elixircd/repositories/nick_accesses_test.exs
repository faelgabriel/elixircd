defmodule ElixIRCd.Repositories.NickAccessesTest do
  use ElixIRCd.DataCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Tables.NickAccess

  describe "create/1" do
    test "creates a new nick access entry" do
      Memento.transaction!(fn ->
        attrs = %{
          nickname: "TestNick",
          mask: "*@example.com"
        }

        result = NickAccesses.create(attrs)

        assert %NickAccess{} = result
        assert result.nickname_key == "testnick"
        assert result.mask == "*@example.com"
        assert %DateTime{} = result.created_at
      end)
    end
  end

  describe "get_by_account_name/1" do
    test "returns empty list when nickname has no access entries" do
      Memento.transaction!(fn ->
        result = NickAccesses.get_by_account_name("TestNick")

        assert result == []
      end)
    end

    test "returns all access entries for a nickname" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask1 = "*@host1.com"
        mask2 = "*@host2.com"

        _entry1 = insert(:nick_access, nickname: nickname, mask: mask1)
        _entry2 = insert(:nick_access, nickname: nickname, mask: mask2)

        result = NickAccesses.get_by_account_name(nickname)

        assert length(result) == 2
        result_masks = Enum.map(result, & &1.mask) |> Enum.sort()
        expected_masks = [mask1, mask2] |> Enum.sort()
        assert result_masks == expected_masks
      end)
    end

    test "returns entries sorted by created_at" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        base_time = DateTime.utc_now()
        time1 = DateTime.add(base_time, -2, :second)
        time2 = DateTime.add(base_time, -1, :second)
        time3 = base_time

        _entry1 = insert(:nick_access, nickname: nickname, mask: "*@host1.com", created_at: time2)
        _entry2 = insert(:nick_access, nickname: nickname, mask: "*@host2.com", created_at: time1)
        _entry3 = insert(:nick_access, nickname: nickname, mask: "*@host3.com", created_at: time3)

        result = NickAccesses.get_by_account_name(nickname)

        assert length(result) == 3
        assert Enum.at(result, 0).mask == "*@host2.com"
        assert Enum.at(result, 1).mask == "*@host1.com"
        assert Enum.at(result, 2).mask == "*@host3.com"
      end)
    end

    test "only returns entries for the specified nickname" do
      Memento.transaction!(fn ->
        nickname1 = "TestNick1"
        nickname2 = "TestNick2"

        insert(:nick_access, nickname: nickname1, mask: "*@host1.com")
        insert(:nick_access, nickname: nickname2, mask: "*@host2.com")

        result = NickAccesses.get_by_account_name(nickname1)

        assert length(result) == 1
        assert hd(result).nickname_key == "testnick1"
      end)
    end

    test "is case-insensitive for nickname matching" do
      Memento.transaction!(fn ->
        nickname = "TestNick"

        insert(:nick_access, nickname: nickname, mask: "*@host.com")

        result1 = NickAccesses.get_by_account_name("TestNick")
        result2 = NickAccesses.get_by_account_name("testnick")
        result3 = NickAccesses.get_by_account_name("TESTNICK")

        assert length(result1) == 1
        assert length(result2) == 1
        assert length(result3) == 1
      end)
    end
  end

  describe "get_by_account_name_and_mask/2" do
    test "returns nil when no matching entry exists" do
      Memento.transaction!(fn ->
        result = NickAccesses.get_by_account_name_and_mask("TestNick", "*@host.com")

        assert result == nil
      end)
    end

    test "returns the matching entry when it exists" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask = "*@host.com"

        entry = insert(:nick_access, nickname: nickname, mask: mask)

        result = NickAccesses.get_by_account_name_and_mask(nickname, mask)

        assert result.nickname_key == entry.nickname_key
        assert result.mask == entry.mask
        assert result.created_at == entry.created_at
      end)
    end

    test "returns correct entry when multiple entries exist for same nickname" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask1 = "*@host1.com"
        mask2 = "*@host2.com"

        entry1 = insert(:nick_access, nickname: nickname, mask: mask1)
        entry2 = insert(:nick_access, nickname: nickname, mask: mask2)

        result1 = NickAccesses.get_by_account_name_and_mask(nickname, mask1)
        result2 = NickAccesses.get_by_account_name_and_mask(nickname, mask2)

        assert result1.mask == mask1
        assert result2.mask == mask2
        assert result1.created_at == entry1.created_at
        assert result2.created_at == entry2.created_at
      end)
    end

    test "is case-insensitive for nickname matching" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask = "*@host.com"

        insert(:nick_access, nickname: nickname, mask: mask)

        result1 = NickAccesses.get_by_account_name_and_mask("TestNick", mask)
        result2 = NickAccesses.get_by_account_name_and_mask("testnick", mask)
        result3 = NickAccesses.get_by_account_name_and_mask("TESTNICK", mask)

        assert result1 != nil
        assert result2 != nil
        assert result3 != nil
      end)
    end

    test "is case-insensitive for mask matching" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        # Factory will normalize this to lowercase
        mask = "*@host.com"

        insert(:nick_access, nickname: nickname, mask: mask)

        result1 = NickAccesses.get_by_account_name_and_mask(nickname, "*@HOST.COM")
        result2 = NickAccesses.get_by_account_name_and_mask(nickname, "*@host.com")
        result3 = NickAccesses.get_by_account_name_and_mask(nickname, "*@Host.Com")

        assert result1 != nil
        assert result2 != nil
        assert result3 != nil
      end)
    end
  end

  describe "count_by_account_name/1" do
    test "returns 0 when nickname has no access entries" do
      Memento.transaction!(fn ->
        result = NickAccesses.count_by_account_name("TestNick")

        assert result == 0
      end)
    end

    test "returns correct count of access entries" do
      Memento.transaction!(fn ->
        nickname = "TestNick"

        insert(:nick_access, nickname: nickname, mask: "*@host1.com")
        insert(:nick_access, nickname: nickname, mask: "*@host2.com")
        insert(:nick_access, nickname: nickname, mask: "*@host3.com")

        result = NickAccesses.count_by_account_name(nickname)

        assert result == 3
      end)
    end

    test "only counts entries for the specified nickname" do
      Memento.transaction!(fn ->
        nickname1 = "TestNick1"
        nickname2 = "TestNick2"

        insert(:nick_access, nickname: nickname1, mask: "*@host1.com")
        insert(:nick_access, nickname: nickname1, mask: "*@host2.com")
        insert(:nick_access, nickname: nickname2, mask: "*@host3.com")

        result = NickAccesses.count_by_account_name(nickname1)

        assert result == 2
      end)
    end

    test "is case-insensitive for nickname matching" do
      Memento.transaction!(fn ->
        nickname = "TestNick"

        insert(:nick_access, nickname: nickname, mask: "*@host.com")

        result1 = NickAccesses.count_by_account_name("TestNick")
        result2 = NickAccesses.count_by_account_name("testnick")
        result3 = NickAccesses.count_by_account_name("TESTNICK")

        assert result1 == 1
        assert result2 == 1
        assert result3 == 1
      end)
    end
  end

  describe "delete/2" do
    test "deletes the specified access entry" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask = "*@host.com"

        insert(:nick_access, nickname: nickname, mask: mask)

        assert NickAccesses.get_by_account_name_and_mask(nickname, mask) != nil
        assert :ok = NickAccesses.delete(nickname, mask)
        assert NickAccesses.get_by_account_name_and_mask(nickname, mask) == nil
      end)
    end

    test "returns :ok when trying to delete non-existent entry" do
      Memento.transaction!(fn ->
        assert :ok = NickAccesses.delete("TestNick", "*@host.com")
      end)
    end

    test "only deletes the specified entry when multiple exist" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask1 = "*@host1.com"
        mask2 = "*@host2.com"

        insert(:nick_access, nickname: nickname, mask: mask1)
        insert(:nick_access, nickname: nickname, mask: mask2)

        assert :ok = NickAccesses.delete(nickname, mask1)
        assert NickAccesses.get_by_account_name_and_mask(nickname, mask1) == nil
        assert NickAccesses.get_by_account_name_and_mask(nickname, mask2) != nil
      end)
    end

    test "is case-insensitive for nickname matching" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask = "*@host.com"

        insert(:nick_access, nickname: nickname, mask: mask)

        assert :ok = NickAccesses.delete("TESTNICK", mask)
        assert NickAccesses.get_by_account_name_and_mask(nickname, mask) == nil
      end)
    end

    test "is case-insensitive for mask matching" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask = "*@host.com"

        insert(:nick_access, nickname: nickname, mask: mask)

        assert :ok = NickAccesses.delete(nickname, "*@HOST.COM")
        assert NickAccesses.get_by_account_name_and_mask(nickname, mask) == nil
      end)
    end
  end

  describe "delete_by_account_name/1" do
    test "deletes all access entries for a nickname" do
      Memento.transaction!(fn ->
        nickname = "TestNick"

        insert(:nick_access, nickname: nickname, mask: "*@host1.com")
        insert(:nick_access, nickname: nickname, mask: "*@host2.com")

        assert length(NickAccesses.get_by_account_name(nickname)) == 2

        assert :ok = NickAccesses.delete_by_account_name(nickname)
        assert NickAccesses.get_by_account_name(nickname) == []
      end)
    end

    test "returns :ok when nickname has no access entries" do
      Memento.transaction!(fn ->
        assert :ok = NickAccesses.delete_by_account_name("TestNick")
      end)
    end

    test "only deletes entries for the specified nickname" do
      Memento.transaction!(fn ->
        nickname1 = "TestNick1"
        nickname2 = "TestNick2"

        insert(:nick_access, nickname: nickname1, mask: "*@host1.com")
        insert(:nick_access, nickname: nickname2, mask: "*@host2.com")

        assert :ok = NickAccesses.delete_by_account_name(nickname1)
        assert NickAccesses.get_by_account_name(nickname1) == []
        assert length(NickAccesses.get_by_account_name(nickname2)) == 1
      end)
    end

    test "is case-insensitive for nickname matching" do
      Memento.transaction!(fn ->
        nickname = "TestNick"

        insert(:nick_access, nickname: nickname, mask: "*@host.com")

        assert :ok = NickAccesses.delete_by_account_name("TESTNICK")
        assert NickAccesses.get_by_account_name(nickname) == []
      end)
    end
  end

  describe "integration tests" do
    test "complete workflow: create, read, count, delete" do
      Memento.transaction!(fn ->
        nickname = "TestNick"
        mask1 = "*@host1.com"
        mask2 = "*@host2.com"

        assert NickAccesses.get_by_account_name(nickname) == []
        assert NickAccesses.count_by_account_name(nickname) == 0

        entry1 = NickAccesses.create(%{nickname: nickname, mask: mask1})
        assert entry1.nickname_key == "testnick"
        assert entry1.mask == mask1

        entries = NickAccesses.get_by_account_name(nickname)
        assert length(entries) == 1
        assert hd(entries).mask == mask1
        assert NickAccesses.count_by_account_name(nickname) == 1

        _entry2 = NickAccesses.create(%{nickname: nickname, mask: mask2})

        entries = NickAccesses.get_by_account_name(nickname)
        assert length(entries) == 2
        entry_masks = Enum.map(entries, & &1.mask) |> Enum.sort()
        expected_masks = [mask1, mask2] |> Enum.sort()
        assert entry_masks == expected_masks
        assert NickAccesses.count_by_account_name(nickname) == 2

        NickAccesses.delete(nickname, mask1)

        entries = NickAccesses.get_by_account_name(nickname)
        assert length(entries) == 1
        assert hd(entries).mask == mask2
        assert NickAccesses.count_by_account_name(nickname) == 1

        NickAccesses.delete_by_account_name(nickname)

        assert NickAccesses.get_by_account_name(nickname) == []
        assert NickAccesses.count_by_account_name(nickname) == 0
      end)
    end
  end
end
