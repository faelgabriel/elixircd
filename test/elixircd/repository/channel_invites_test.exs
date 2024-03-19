defmodule ElixIRCd.Repository.ChannelInvitesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repository.ChannelInvites
  alias ElixIRCd.Tables.ChannelInvite

  describe "create/1" do
    test "creates a new channel invite" do
      attrs = %{
        channel_name: "#elixircd",
        user_mask: "user!user@host",
        setter: "setter!setter@host"
      }

      channel_invite = Memento.transaction!(fn -> ChannelInvites.create(attrs) end)

      assert channel_invite.channel_name == "#elixircd"
      assert channel_invite.user_mask == "user!user@host"
      assert channel_invite.setter == "setter!setter@host"
    end
  end

  describe "get_by_channel_name_and_user_mask/2" do
    test "gets a channel invite by the channel name and user mask" do
      channel_invite = insert(:channel_invite)

      assert {:ok, %ChannelInvite{}} =
               Memento.transaction!(fn ->
                 ChannelInvites.get_by_channel_name_and_user_mask(channel_invite.channel_name, channel_invite.user_mask)
               end)
    end

    test "returns an error when the channel invite is not found" do
      assert {:error, :channel_invite_not_found} =
               Memento.transaction!(fn ->
                 ChannelInvites.get_by_channel_name_and_user_mask("#elixircd", "user!user@host")
               end)
    end
  end
end
