defmodule ElixIRCd.Repository.ChannelBansTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repository.ChannelBans
  alias ElixIRCd.Tables.ChannelBan

  describe "create/1" do
    test "creates a new channel ban" do
      attrs = %{
        channel_name: "#elixircd",
        mask: "user!user@host",
        setter: "setter!setter@host"
      }

      channel_ban = Memento.transaction!(fn -> ChannelBans.create(attrs) end)

      assert channel_ban.channel_name == "#elixircd"
      assert channel_ban.mask == "user!user@host"
      assert channel_ban.setter == "setter!setter@host"
    end
  end

  describe "delete/1" do
    test "deletes a channel ban" do
      channel_ban = insert(:channel_ban)
      Memento.transaction!(fn -> ChannelBans.delete(channel_ban) end)
      assert nil == Memento.transaction!(fn -> Memento.Query.read(ChannelBan, channel_ban.channel_name) end)
    end
  end

  describe "get_by_channel_name/1" do
    test "gets channel bans by the channel name" do
      channel_ban = insert(:channel_ban)
      assert [%ChannelBan{}] = Memento.transaction!(fn -> ChannelBans.get_by_channel_name(channel_ban.channel_name) end)
    end
  end

  describe "get_by_channel_name_and_mask/2" do
    test "gets a channel ban by the channel name and mask" do
      channel_ban = insert(:channel_ban)

      assert {:ok, %ChannelBan{}} =
               Memento.transaction!(fn ->
                 ChannelBans.get_by_channel_name_and_mask(channel_ban.channel_name, channel_ban.mask)
               end)
    end

    test "returns an error when the channel ban is not found" do
      assert {:error, "ChannelBan not found"} =
               Memento.transaction!(fn ->
                 ChannelBans.get_by_channel_name_and_mask("#elixircd", "user!user@host")
               end)
    end
  end
end
