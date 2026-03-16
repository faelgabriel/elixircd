defmodule ElixIRCd.Services.Chanserv.Channel.ContextTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Channel.Context

  describe "get_registered_channel/1" do
    test "returns the registered channel when it exists" do
      Memento.transaction!(fn ->
        registered_channel = insert(:registered_channel, name: "#registered")

        assert {:ok, found_channel} = Context.get_registered_channel("#registered")
        assert found_channel.name == registered_channel.name
      end)
    end

    test "returns an error when the registered channel does not exist" do
      Memento.transaction!(fn ->
        assert {:error, :registered_channel_not_found} = Context.get_registered_channel("#missing")
      end)
    end
  end

  describe "get_access_entries/1" do
    test "normalizes persisted access flags" do
      Memento.transaction!(fn ->
        insert(:registered_channel_access, channel_name: "#registered", account_name: "alice", flags: "fav")
        insert(:registered_channel_access, channel_name: "#registered", account_name: "bob", flags: "ssv")

        assert %{"alice" => "VAF", "bob" => "VS"} = Context.get_access_entries("#registered")
      end)
    end
  end

  describe "get_online_channel/1" do
    test "returns the online channel when it exists" do
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#online")

        assert {:ok, found_channel} = Context.get_online_channel("#online")
        assert found_channel.name == channel.name
      end)
    end

    test "maps repository not found errors to channel_not_in_use" do
      Memento.transaction!(fn ->
        assert {:error, :channel_not_in_use} = Context.get_online_channel("#missing")
      end)
    end
  end

  describe "get_online_channel_state/1" do
    test "returns the channel, its user channels, and the online users" do
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#online")
        first_user = insert(:user, nick: "alice")
        second_user = insert(:user, nick: "bob")

        first_user_channel = insert(:user_channel, channel: channel, user: first_user)
        second_user_channel = insert(:user_channel, channel: channel, user: second_user)

        assert {:ok, found_channel, user_channels, users} = Context.get_online_channel_state("#online")

        assert found_channel.name == channel.name

        assert Enum.sort(Enum.map(user_channels, & &1.user_pid)) ==
                 Enum.sort([first_user_channel.user_pid, second_user_channel.user_pid])

        assert Enum.sort(Enum.map(users, & &1.pid)) == Enum.sort([first_user.pid, second_user.pid])
      end)
    end

    test "returns an error when the channel is not in use" do
      Memento.transaction!(fn ->
        assert {:error, :channel_not_in_use} = Context.get_online_channel_state("#missing")
      end)
    end
  end
end
