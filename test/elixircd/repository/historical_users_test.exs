defmodule ElixIRCd.Repository.HistoricalUsersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repository.HistoricalUsers
  alias ElixIRCd.Tables.HistoricalUser

  describe "create/1" do
    test "creates a new historical user" do
      attrs = %{
        nick: "testnick",
        hostname: "testhostname",
        username: "testusername",
        realname: "testrealname",
        created_at: DateTime.utc_now()
      }

      historical_user = Memento.transaction!(fn -> HistoricalUsers.create(attrs) end)

      assert historical_user.nick == attrs.nick
      assert historical_user.hostname == attrs.hostname
      assert historical_user.username == attrs.username
      assert historical_user.realname == attrs.realname
      assert historical_user.userid == nil
      assert historical_user.created_at == attrs.created_at
    end
  end

  describe "get_by_nick/2" do
    test "returns historical users by nick with limit" do
      insert(:historical_user, nick: "test")
      insert(:historical_user, nick: "test")

      assert [%HistoricalUser{}] =
               Memento.transaction!(fn -> HistoricalUsers.get_by_nick("test", 1) end)
    end

    test "returns historical users by nick with limit as nil" do
      insert(:historical_user, nick: "test")
      insert(:historical_user, nick: "test")

      assert [%HistoricalUser{}, %HistoricalUser{}] =
               Memento.transaction!(fn -> HistoricalUsers.get_by_nick("test", nil) end)
    end
  end
end
