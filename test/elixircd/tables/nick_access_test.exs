defmodule ElixIRCd.Tables.NickAccessTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.NickAccess

  describe "new/1" do
    test "creates a new nick access entry with nickname" do
      attrs = %{
        nickname: "TestNick",
        mask: "*@example.com"
      }

      nick_access = NickAccess.new(attrs)

      assert nick_access.nickname_key == "testnick"
      assert nick_access.mask == "*@example.com"
      assert %DateTime{} = nick_access.created_at
    end

    test "creates a new nick access entry with nickname_key directly" do
      attrs = %{
        nickname_key: "testnick",
        mask: "*@example.com"
      }

      nick_access = NickAccess.new(attrs)

      assert nick_access.nickname_key == "testnick"
      assert nick_access.mask == "*@example.com"
      assert %DateTime{} = nick_access.created_at
    end

    test "normalizes nickname to nickname_key" do
      attrs = %{
        nickname: "TeStNiCk",
        mask: "*@example.com"
      }

      nick_access = NickAccess.new(attrs)

      assert nick_access.nickname_key == "testnick"
    end

    test "normalizes mask to lowercase" do
      attrs = %{
        nickname: "TestNick",
        mask: "*@EXAMPLE.COM"
      }

      nick_access = NickAccess.new(attrs)

      assert nick_access.mask == "*@example.com"
    end

    test "uses current time as created_at if not provided" do
      before_test = DateTime.utc_now()

      nick_access =
        NickAccess.new(%{
          nickname: "TestNick",
          mask: "*@example.com"
        })

      after_test = DateTime.utc_now()

      assert DateTime.compare(before_test, nick_access.created_at) in [:lt, :eq]
      assert DateTime.compare(nick_access.created_at, after_test) in [:lt, :eq]
    end

    test "uses provided created_at when given" do
      custom_time = ~U[2024-01-01 00:00:00Z]

      attrs = %{
        nickname: "TestNick",
        mask: "*@example.com",
        created_at: custom_time
      }

      nick_access = NickAccess.new(attrs)

      assert nick_access.created_at == custom_time
    end

    test "handles attrs without mask" do
      attrs = %{
        nickname: "TestNick"
      }

      assert_raise ArgumentError, fn ->
        NickAccess.new(attrs)
      end
    end

    test "handles empty attrs" do
      assert_raise ArgumentError, fn ->
        NickAccess.new(%{})
      end
    end

    test "handles attrs with nickname_key already normalized" do
      attrs = %{
        nickname_key: "already-normalized",
        mask: "*@example.com"
      }

      nick_access = NickAccess.new(attrs)

      assert nick_access.nickname_key == "already-normalized"
      assert nick_access.mask == "*@example.com"
    end

    test "accepts nickname_key directly without nickname" do
      attrs = %{
        nickname_key: "explicit-key",
        mask: "*@example.com"
      }

      nick_access = NickAccess.new(attrs)

      assert nick_access.nickname_key == "explicit-key"
    end

    test "handles various mask formats" do
      test_cases = [
        {"*@host.com", "*@host.com"},
        {"user@HOST.COM", "user@host.com"},
        {"~user@*.EXAMPLE.com", "~user@*.example.com"},
        {"?ser@host?.COM", "?ser@host?.com"}
      ]

      for {input_mask, expected_mask} <- test_cases do
        nick_access = NickAccess.new(%{nickname: "TestNick", mask: input_mask})
        assert nick_access.mask == expected_mask, "Failed for mask: #{input_mask}"
      end
    end

    test "preserves wildcard characters in mask" do
      attrs = %{
        nickname: "TestNick",
        mask: "*@*.example.com"
      }

      nick_access = NickAccess.new(attrs)

      assert nick_access.mask == "*@*.example.com"
    end

    test "normalizes nickname using case mapping" do
      test_cases = [
        {"TestNick", "testnick"},
        {"TESTNICK", "testnick"},
        {"test_nick", "test_nick"},
        {"test-nick", "test-nick"}
      ]

      for {input_nick, expected_key} <- test_cases do
        nick_access = NickAccess.new(%{nickname: input_nick, mask: "*@example.com"})
        assert nick_access.nickname_key == expected_key, "Failed for nickname: #{input_nick}"
      end
    end
  end
end
