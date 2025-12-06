defmodule ElixIRCd.Repositories.ChannelInvexesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Tables.ChannelInvex

  describe "create/1" do
    test "creates a new channel invex" do
      attrs = %{
        channel_name_key: "#elixircd",
        mask: "user!user@host",
        setter: "setter!setter@host"
      }

      channel_invex = Memento.transaction!(fn -> ChannelInvexes.create(attrs) end)

      assert channel_invex.channel_name_key == "#elixircd"
      assert channel_invex.mask == "user!user@host"
      assert channel_invex.setter == "setter!setter@host"
    end
  end

  describe "delete/1" do
    test "deletes a channel invex" do
      channel_invex = insert(:channel_invex)
      Memento.transaction!(fn -> ChannelInvexes.delete(channel_invex) end)
      assert nil == Memento.transaction!(fn -> Memento.Query.read(ChannelInvex, channel_invex.channel_name_key) end)
    end
  end

  describe "get_by_channel_name_key/1" do
    test "gets channel invexes by the channel name" do
      channel_invex = insert(:channel_invex)

      assert [%ChannelInvex{}] =
               Memento.transaction!(fn -> ChannelInvexes.get_by_channel_name_key(channel_invex.channel_name_key) end)
    end
  end

  describe "get_by_channel_name_key_and_mask/2" do
    test "gets a channel invex by the channel name key and mask" do
      channel_invex = insert(:channel_invex)

      assert {:ok, %ChannelInvex{}} =
               Memento.transaction!(fn ->
                 ChannelInvexes.get_by_channel_name_key_and_mask(channel_invex.channel_name_key, channel_invex.mask)
               end)
    end

    test "returns an error when the channel invex is not found" do
      assert {:error, :channel_invex_not_found} =
               Memento.transaction!(fn ->
                 ChannelInvexes.get_by_channel_name_key_and_mask("#elixircd", "user!user@host")
               end)
    end
  end
end
