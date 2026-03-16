defmodule ElixIRCd.Repositories.RegisteredChannelAccessesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannelAccesses

  describe "create/1 and get_by_channel_name/1" do
    test "stores and lists access entries for a channel" do
      Memento.transaction!(fn ->
        RegisteredChannelAccesses.create(%{
          channel_name: "#testchannel",
          account_name: "helper",
          flags: "VAF"
        })

        [entry] = RegisteredChannelAccesses.get_by_channel_name("#testchannel")

        assert entry.account_name == "helper"
        assert entry.flags == "VAF"
      end)
    end
  end

  describe "get_by_channel_name_and_account_name/2" do
    test "returns nil for missing entries" do
      assert nil ==
               Memento.transaction!(fn ->
                 RegisteredChannelAccesses.get_by_channel_name_and_account_name("#missing", "helper")
               end)
    end
  end

  describe "get_flags_map_by_channel_name/1" do
    test "returns a map keyed by account name" do
      insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "VA")
      insert(:registered_channel_access, channel_name: "#testchannel", account_name: "staff", flags: "VAF")

      flags_map =
        Memento.transaction!(fn -> RegisteredChannelAccesses.get_flags_map_by_channel_name("#testchannel") end)

      assert flags_map == %{"helper" => "VA", "staff" => "VAF"}
    end
  end

  describe "get_by_account_name/1" do
    test "lists all channel access entries for an account" do
      insert(:registered_channel_access, channel_name: "#alpha", account_name: "helper", flags: "VA")
      insert(:registered_channel_access, channel_name: "#beta", account_name: "helper", flags: "VAF")

      entries = Memento.transaction!(fn -> RegisteredChannelAccesses.get_by_account_name("helper") end)

      assert Enum.map(entries, & &1.channel_name_key) == ["#alpha", "#beta"]
    end
  end

  describe "delete/2 and delete_by_channel_name/1" do
    test "deletes specific and channel-wide access entries" do
      insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "VA")
      insert(:registered_channel_access, channel_name: "#testchannel", account_name: "staff", flags: "VAF")

      Memento.transaction!(fn -> RegisteredChannelAccesses.delete("#testchannel", "helper") end)

      assert %{"staff" => "VAF"} ==
               Memento.transaction!(fn -> RegisteredChannelAccesses.get_flags_map_by_channel_name("#testchannel") end)

      Memento.transaction!(fn -> RegisteredChannelAccesses.delete_by_channel_name("#testchannel") end)

      assert %{} ==
               Memento.transaction!(fn -> RegisteredChannelAccesses.get_flags_map_by_channel_name("#testchannel") end)
    end
  end
end
