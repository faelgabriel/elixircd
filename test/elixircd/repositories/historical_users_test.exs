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
    test "returns historical users by nick" do
      insert(:historical_user, nick: "Test")
      insert(:historical_user, nick: "Test")

      assert [%HistoricalUser{}] =
               Memento.transaction!(fn -> HistoricalUsers.get_by_nick("test", 1) end)
    end
  end

  describe "get_by_nick_key/2" do
    test "returns historical users by nick_key with limit" do
      insert(:historical_user, nick: "Test")
      insert(:historical_user, nick: "Test")

      assert [%HistoricalUser{}] =
               Memento.transaction!(fn -> HistoricalUsers.get_by_nick_key("test", 1) end)
    end

    test "returns historical users by nick_key with limit as nil" do
      insert(:historical_user, nick: "Test")
      insert(:historical_user, nick: "Test")

      assert [%HistoricalUser{}, %HistoricalUser{}] =
               Memento.transaction!(fn -> HistoricalUsers.get_by_nick_key("test", nil) end)
    end
  end
end
