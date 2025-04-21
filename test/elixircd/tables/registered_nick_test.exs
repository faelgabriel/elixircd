defmodule ElixIRCd.Tables.RegisteredNickTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "new/1" do
    test "creates a new registered nick with required attributes" do
      attrs = %{
        nickname: "testnick",
        password_hash: "hash123",
        registered_by: "user@host"
      }

      registered_nick = RegisteredNick.new(attrs)

      assert registered_nick.nickname == "testnick"
      assert registered_nick.password_hash == "hash123"
      assert registered_nick.registered_by == "user@host"
      assert registered_nick.email == nil
      assert registered_nick.verify_code == nil
      assert registered_nick.verified_at == nil
      assert registered_nick.reserved_until == nil
      assert %RegisteredNick.Settings{} = registered_nick.settings
      assert %DateTime{} = registered_nick.created_at
    end

    test "creates a new registered nick with custom settings" do
      custom_settings = Settings.new() |> Settings.update(%{hide_email: true})

      attrs = %{
        nickname: "testnick",
        password_hash: "hash123",
        registered_by: "user@host",
        email: "test@example.com",
        settings: custom_settings
      }

      registered_nick = RegisteredNick.new(attrs)

      assert registered_nick.email == "test@example.com"
      assert registered_nick.settings.hide_email == true
    end

    test "uses current time as created_at if not provided" do
      before_test = DateTime.utc_now()

      registered_nick =
        RegisteredNick.new(%{
          nickname: "testnick",
          password_hash: "hash123",
          registered_by: "user@host"
        })

      after_test = DateTime.utc_now()

      assert DateTime.compare(before_test, registered_nick.created_at) in [:lt, :eq]
      assert DateTime.compare(registered_nick.created_at, after_test) in [:lt, :eq]
    end
  end

  describe "update/2" do
    test "updates a registered nick with new values" do
      registered_nick = %RegisteredNick{
        nickname: "testnick",
        password_hash: "hash123",
        registered_by: "user@host",
        email: nil,
        verify_code: nil,
        verified_at: nil,
        last_seen_at: nil,
        reserved_until: nil,
        settings: Settings.new(),
        created_at: DateTime.utc_now()
      }

      attrs = %{
        email: "updated@example.com",
        verified_at: DateTime.utc_now()
      }

      updated_nick = RegisteredNick.update(registered_nick, attrs)

      assert updated_nick.email == "updated@example.com"
      assert updated_nick.verified_at != nil
    end

    test "preserves existing values when not specified in update" do
      timestamp = DateTime.utc_now()

      registered_nick = %RegisteredNick{
        nickname: "testnick",
        password_hash: "hash123",
        registered_by: "user@host",
        email: "original@example.com",
        verify_code: "123456",
        verified_at: timestamp,
        last_seen_at: nil,
        reserved_until: nil,
        settings: Settings.new(),
        created_at: timestamp
      }

      attrs = %{
        last_seen_at: DateTime.utc_now()
      }

      updated_nick = RegisteredNick.update(registered_nick, attrs)

      assert updated_nick.email == "original@example.com"
      assert updated_nick.verify_code == "123456"
      assert updated_nick.verified_at == timestamp
      assert updated_nick.last_seen_at != nil
      assert updated_nick.nickname == "testnick"
    end
  end
end
