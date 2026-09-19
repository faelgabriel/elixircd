defmodule ElixIRCd.Repositories.HistoricalUsersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.HistoricalUsers
  alias ElixIRCd.Tables.HistoricalUser

  describe "create/1" do
    test "creates a new historical user" do
      attrs = %{
        nick_key: "testnick",
        nick: "Testnick",
        hostname: "testhostname",
        ident: "testusername",
        realname: "testrealname",
        created_at: DateTime.utc_now()
      }

      historical_user = Memento.transaction!(fn -> HistoricalUsers.create(attrs) end)

      assert historical_user.nick_key == attrs.nick_key
      assert historical_user.nick == attrs.nick
      assert historical_user.hostname == attrs.hostname
      assert historical_user.ident == attrs.ident
      assert historical_user.realname == attrs.realname
      assert historical_user.created_at == attrs.created_at
    end
  end

  describe "get_by_nick/2" do
    test "sorts all matching rows before limiting, including committed history" do
      older = insert(:historical_user, nick: "Test", created_at: ~U[2026-09-14 00:00:00Z])
      newest = insert(:historical_user, nick: "Test", created_at: ~U[2026-09-14 00:00:02Z])
      middle = insert(:historical_user, nick: "Test", created_at: ~U[2026-09-14 00:00:01Z])

      Memento.transaction!(fn ->
        assert HistoricalUsers.get_by_nick("TEST", 1) == [newest]
        assert HistoricalUsers.get_by_nick("test", 2) == [newest, middle]
        assert HistoricalUsers.get_by_nick("test", nil) == [newest, middle, older]
        assert HistoricalUsers.get_by_nick("test", 0) == []
      end)
    end

    test "returns historical users by nick" do
      insert(:historical_user, nick: "Test")
      insert(:historical_user, nick: "Test")

      assert [%HistoricalUser{}] =
               Memento.transaction!(fn -> HistoricalUsers.get_by_nick("test", 1) end)
    end
  end

  describe "get_by_mask/2" do
    test "uses IRC casemapping wildcards and applies the result limit after sorting" do
      older = insert(:historical_user, nick: "NickTwo", created_at: ~U[2026-09-14 00:00:00Z])
      newest = insert(:historical_user, nick: "NickOne", created_at: ~U[2026-09-14 00:00:02Z])
      insert(:historical_user, nick: "Other", created_at: ~U[2026-09-14 00:00:03Z])

      Memento.transaction!(fn ->
        assert HistoricalUsers.get_by_mask("nIck*", nil) == [newest, older]
        assert HistoricalUsers.get_by_mask("nick?ne", 1) == [newest]
      end)
    end
  end
end
