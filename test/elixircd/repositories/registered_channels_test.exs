defmodule ElixIRCd.Repositories.RegisteredChannelsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Tables.RegisteredChannel

  describe "create/1" do
    test "creates a new registered channel" do
      attrs = %{
        name: "#testchannel",
        founder: "testfounder",
        password_hash: "hash123",
        registered_by: "user@host"
      }

      registered_channel = Memento.transaction!(fn -> RegisteredChannels.create(attrs) end)

      assert registered_channel.name == "#testchannel"
      assert registered_channel.founder == "testfounder"
      assert registered_channel.password_hash == "hash123"
      assert registered_channel.registered_by == "user@host"
    end
  end

  describe "get_by_name/1" do
    test "returns a registered channel by its name" do
      registered_channel = insert(:registered_channel)

      assert {:ok, retrieved_channel} =
               Memento.transaction!(fn -> RegisteredChannels.get_by_name(registered_channel.name) end)

      assert retrieved_channel.name == registered_channel.name
      assert retrieved_channel.founder == registered_channel.founder
    end

    test "returns an error when the registered channel is not found" do
      assert {:error, :registered_channel_not_found} ==
               Memento.transaction!(fn -> RegisteredChannels.get_by_name("#nonexistent") end)
    end
  end

  describe "get_all/0" do
    test "returns all registered channels" do
      registered_channel1 = insert(:registered_channel)
      registered_channel2 = insert(:registered_channel)

      registered_channels = Memento.transaction!(fn -> RegisteredChannels.get_all() end)

      assert length(registered_channels) == 2
      assert Enum.any?(registered_channels, fn channel -> channel.name == registered_channel1.name end)
      assert Enum.any?(registered_channels, fn channel -> channel.name == registered_channel2.name end)
    end

    test "returns an empty list when no registered channels exist" do
      # Our setup ensures the table is empty
      assert [] == Memento.transaction!(fn -> RegisteredChannels.get_all() end)
    end
  end

  describe "get_by_founder/1" do
    test "returns all registered channels for a founder" do
      founder = "testfounder"
      registered_channel1 = insert(:registered_channel, founder: founder)
      registered_channel2 = insert(:registered_channel, founder: founder)
      # different founder
      insert(:registered_channel)

      registered_channels = Memento.transaction!(fn -> RegisteredChannels.get_by_founder(founder) end)

      assert length(registered_channels) == 2
      assert Enum.any?(registered_channels, fn channel -> channel.name == registered_channel1.name end)
      assert Enum.any?(registered_channels, fn channel -> channel.name == registered_channel2.name end)
    end

    test "returns an empty list when the founder has no registered channels" do
      assert [] == Memento.transaction!(fn -> RegisteredChannels.get_by_founder("nonexistent") end)
    end
  end

  describe "update/2" do
    test "updates a registered channel with new values" do
      registered_channel = insert(:registered_channel)

      attrs = %{
        password_hash: "newhash123"
      }

      updated_channel = Memento.transaction!(fn -> RegisteredChannels.update(registered_channel, attrs) end)

      assert updated_channel.password_hash == "newhash123"
      assert updated_channel.name == registered_channel.name
      assert updated_channel.founder == registered_channel.founder
    end

    test "updates a registered channel settings" do
      registered_channel = insert(:registered_channel)

      custom_settings =
        registered_channel.settings
        |> RegisteredChannel.Settings.update(%{private: true, guard: false})

      attrs = %{
        settings: custom_settings
      }

      updated_channel = Memento.transaction!(fn -> RegisteredChannels.update(registered_channel, attrs) end)

      assert updated_channel.settings.private == true
      assert updated_channel.settings.guard == false
    end
  end

  describe "delete/1" do
    test "deletes a registered channel" do
      registered_channel = insert(:registered_channel)

      Memento.transaction!(fn -> RegisteredChannels.delete(registered_channel) end)

      assert nil == Memento.transaction!(fn -> Memento.Query.read(RegisteredChannel, registered_channel.name_key) end)
    end
  end
end
