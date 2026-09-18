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
      assert {:ok, "+kl 25 secret"} = ModeLock.validate("+kl", ["25", "secret"])
      assert {:ok, "-n"} = ModeLock.validate("-n", [])
    end

    test "rejects malformed, incomplete, list, membership, and empty locks" do
      assert {:error, :invalid_mode} = ModeLock.validate("+?", [])
      assert {:error, :missing_mode_parameter} = ModeLock.validate("+k", [])
      assert {:error, :listing_mode} = ModeLock.validate("+b", [])
      assert {:error, :unsupported_mode} = ModeLock.validate("+b", ["*!*@*"])
      assert {:error, :unsupported_mode} = ModeLock.validate("+o", ["account"])
      assert {:error, :empty_mode_lock} = ModeLock.validate("+", [])
      assert {:error, :invalid_mode} = ModeLock.validate(nil, [])
      assert {:error, :invalid_mode} = ModeLock.validate(<<255>>, [])
    end
  end

  describe "parse/1" do
    test "parses only canonical persisted expressions" do
      assert {:ok, [{:add, :n}, {:add, :t}]} = ModeLock.parse("+nt")
      assert {:ok, [{:add, {:k, "secret"}}]} = ModeLock.parse("+k secret")
      assert :error = ModeLock.parse(nil)
      assert :error = ModeLock.parse("")
      assert :error = ModeLock.parse("+k")
      assert :error = ModeLock.parse("+nt extra")
      assert :error = ModeLock.parse(123)
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
      {updated_channel, changes} = ModeLock.reconcile_and_broadcast(channel, registered_channel, actor)

      assert updated_channel.modes == [:n, :t]
      assert changes == [{:add, :n}, {:add, :t}]

      assert_sent_messages([
        {actor.pid, ":ChanServ!service@irc.test MODE #locked +nt\r\n"}
      ])

      {same_channel, no_changes} = ModeLock.reconcile(updated_channel, registered_channel, actor)
      assert Enum.sort(same_channel.modes) == [:n, :t]
      assert no_changes == []
    end)
  end

  test "ignores invalid persisted mode locks" do
    Memento.transaction!(fn ->
      actor = insert(:user)
      channel = insert(:channel)
      registered_channel = build(:registered_channel, settings: Settings.new(%{mlock: "+k"}))

      assert {^channel, []} = ModeLock.reconcile(channel, registered_channel, actor)
    end)
  end
end
