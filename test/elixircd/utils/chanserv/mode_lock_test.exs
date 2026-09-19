defmodule ElixIRCd.Utils.Chanserv.ModeLockTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Tables.RegisteredChannel.Settings
  alias ElixIRCd.Utils.Chanserv.ModeLock

  describe "validate/2" do
    test "canonicalizes stable modes and valued modes" do
      assert {:ok, "+nt"} = ModeLock.validate("+nt", [])
      assert {:ok, "+lk 25 secret"} = ModeLock.validate("+lk", ["25", "secret"])
      assert {:ok, "-n"} = ModeLock.validate("-n", [])
    end

    test "rejects malformed, incomplete, list, membership, and empty locks" do
      assert {:error, :invalid_mode} = ModeLock.validate("+?", [])
      assert {:error, :missing_mode_parameter} = ModeLock.validate("+k", [])
      assert {:error, :invalid_mode_parameter} = ModeLock.validate("+l", ["abc"])
      assert {:error, :invalid_mode_parameter} = ModeLock.validate("+lk", ["0", "secret"])
      assert {:error, :listing_mode} = ModeLock.validate("+b", [])
      assert {:error, :unsupported_mode} = ModeLock.validate("+b", ["*!*@*"])
      assert {:error, :unsupported_mode} = ModeLock.validate("+o", ["account"])
      assert {:error, :empty_mode_lock} = ModeLock.validate("+", [])
      assert {:error, :invalid_mode} = ModeLock.validate(nil, [])
      assert {:error, :invalid_mode} = ModeLock.validate(<<255>>, [])
    end
  end

  test "reconciles and broadcasts a live channel mode lock" do
    Memento.transaction!(fn ->
      actor = insert(:user, nick: "founder")
      channel = insert(:channel, name: "#locked")
      insert(:user_channel, user: actor, channel: channel, modes: [:o])

      insert(:registered_channel,
        name: channel.name,
        founder: actor.nick,
        settings: Settings.new(%{mlock: "+nt"})
      )

      {:ok, registered_channel} = RegisteredChannels.get_by_name(channel.name)
      {updated_channel, changes} = ModeLock.reconcile_and_broadcast(channel, registered_channel)

      assert updated_channel.modes == [:n, :t]
      assert changes == [{:add, :n}, {:add, :t}]

      assert_sent_messages([
        {actor.pid, ":ChanServ!service@irc.test MODE #locked +nt\r\n"}
      ])

      {same_channel, no_changes} = ModeLock.reconcile_and_broadcast(updated_channel, registered_channel)
      assert Enum.sort(same_channel.modes) == [:n, :t]
      assert no_changes == []
    end)
  end

  test "ignores invalid persisted mode locks" do
    Memento.transaction!(fn ->
      channel = insert(:channel)

      for mode_lock <- [nil, "", "+k", "+nt extra", 123] do
        registered_channel = build(:registered_channel, settings: Settings.new(%{mlock: mode_lock}))
        assert {^channel, []} = ModeLock.reconcile_and_broadcast(channel, registered_channel)
      end
    end)
  end
end
