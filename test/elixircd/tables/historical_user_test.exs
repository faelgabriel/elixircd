defmodule ElixIRCd.Tables.HistoricalUserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.HistoricalUser

  describe "new/1" do
    test "creates a new historical user with default values" do
      utc_now = DateTime.utc_now()

      attrs = %{
        nick: "test",
        hostname: "example.com",
        ident: "test",
        realname: "Test User"
      }

      historical_user = HistoricalUser.new(attrs)

      assert historical_user.nick == "test"
      assert historical_user.hostname == "example.com"
      assert historical_user.ident == "test"
      assert historical_user.realname == "Test User"
      assert DateTime.diff(utc_now, historical_user.created_at) < 1000
    end

    test "creates a new historical user with custom values" do
      utc_now = DateTime.utc_now()

      attrs = %{
        nick: "test",
        hostname: "example.com",
        ident: "test",
        realname: "Test User",
        created_at: utc_now
      }

      historical_user = HistoricalUser.new(attrs)

      assert historical_user.nick == "test"
      assert historical_user.hostname == "example.com"
      assert historical_user.ident == "test"
      assert historical_user.realname == "Test User"
      assert historical_user.created_at == utc_now
    end
  end
end
