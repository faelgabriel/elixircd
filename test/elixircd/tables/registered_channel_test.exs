defmodule ElixIRCd.Tables.RegisteredChannelTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.RegisteredChannel.Settings

  describe "new/1" do
    test "creates a new registered channel with required attributes" do
      attrs = %{
        name: "#testchannel",
        founder: "testfounder",
        password_hash: "hash123",
        registered_by: "user@host"
      }

      registered_channel = RegisteredChannel.new(attrs)

      assert registered_channel.name == "#testchannel"
      assert registered_channel.founder == "testfounder"
      assert registered_channel.password_hash == "hash123"
      assert registered_channel.registered_by == "user@host"
      assert %RegisteredChannel.Settings{} = registered_channel.settings
      assert %DateTime{} = registered_channel.created_at
    end

    test "creates a new registered channel with custom settings" do
      custom_settings = Settings.new() |> Settings.update(%{guard: false, private: true})

      attrs = %{
        name: "#testchannel",
        founder: "testfounder",
        password_hash: "hash123",
        registered_by: "user@host",
        settings: custom_settings
      }

      registered_channel = RegisteredChannel.new(attrs)

      assert registered_channel.settings.guard == false
      assert registered_channel.settings.private == true
    end

    test "uses current time as created_at if not provided" do
      before_test = DateTime.add(DateTime.utc_now(), -1)

      registered_channel =
        RegisteredChannel.new(%{
          name: "#testchannel",
          founder: "testfounder",
          password_hash: "hash123",
          registered_by: "user@host"
        })

      after_test = DateTime.add(DateTime.utc_now(), 1)

      assert DateTime.compare(before_test, registered_channel.created_at) in [:lt, :eq]
      assert DateTime.compare(registered_channel.created_at, after_test) in [:lt, :eq]
    end

    test "truncates created_at to the second" do
      registered_channel =
        RegisteredChannel.new(%{
          name: "#testchannel",
          founder: "testfounder",
          password_hash: "hash123",
          registered_by: "user@host"
        })

      assert registered_channel.created_at.microsecond == {0, 0}
    end
  end

  describe "update/2" do
    test "updates a registered channel with new values" do
      registered_channel = %RegisteredChannel{
        name: "#testchannel",
        founder: "testfounder",
        password_hash: "hash123",
        registered_by: "user@host",
        settings: Settings.new(),
        created_at: DateTime.utc_now()
      }

      attrs = %{
        password_hash: "newhash456"
      }

      updated_channel = RegisteredChannel.update(registered_channel, attrs)

      assert updated_channel.password_hash == "newhash456"
    end

    test "preserves existing values when not specified in update" do
      timestamp = DateTime.utc_now()

      settings = Settings.new() |> Settings.update(%{description: "Original description"})

      registered_channel = %RegisteredChannel{
        name: "#testchannel",
        founder: "testfounder",
        password_hash: "hash123",
        registered_by: "user@host",
        settings: settings,
        created_at: timestamp
      }

      attrs = %{
        password_hash: "newhash456"
      }

      updated_channel = RegisteredChannel.update(registered_channel, attrs)

      assert updated_channel.name == "#testchannel"
      assert updated_channel.founder == "testfounder"
      assert updated_channel.registered_by == "user@host"
      assert updated_channel.settings.description == "Original description"
      assert updated_channel.created_at == timestamp
    end
  end
end
