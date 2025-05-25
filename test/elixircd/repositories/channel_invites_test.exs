defmodule ElixIRCd.Repositories.ChannelInvitesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Tables.ChannelInvite

  describe "create/1" do
    test "creates a new channel invite" do
      pid = spawn(fn -> :ok end)

      attrs = %{
        user_pid: pid,
        channel_name_key: "#elixircd",
        setter: "setter!setter@host"
      }

      channel_invite = Memento.transaction!(fn -> ChannelInvites.create(attrs) end)

      assert channel_invite.user_pid == pid
      assert channel_invite.channel_name_key == "#elixircd"
      assert channel_invite.setter == "setter!setter@host"
    end
  end

  describe "delete_by_channel_name/1" do
    test "deletes channel invites by channel name" do
      channel = insert(:channel)
      insert(:channel_invite, channel: channel)
      insert(:channel_invite, channel: channel)

      Memento.transaction!(fn -> ChannelInvites.delete_by_channel_name(channel.name) end)

      assert [] ==
               Memento.transaction!(fn ->
                 Memento.Query.select(ChannelInvite, {:==, :channel_name_key, channel.name_key})
               end)
    end
  end

  describe "delete_by_user_pid/1" do
    test "deletes user channels by user pid" do
      user = insert(:user)
      insert(:channel_invite, user: user)
      insert(:channel_invite, user: user)

      Memento.transaction!(fn -> ChannelInvites.delete_by_user_pid(user.pid) end)

      assert [] ==
               Memento.transaction!(fn ->
                 Memento.Query.select(ChannelInvite, {:==, :user_pid, user.pid})
               end)
    end
  end

  describe "get_by_user_pid_and_channel_name/2" do
    test "gets a channel invite by the channel name and user pid" do
      channel_invite = insert(:channel_invite)

      assert {:ok, %ChannelInvite{}} =
               Memento.transaction!(fn ->
                 ChannelInvites.get_by_user_pid_and_channel_name(
                   channel_invite.user_pid,
                   channel_invite.channel_name_key
                 )
               end)
    end

    test "returns an error when the channel invite is not found" do
      pid = spawn(fn -> :ok end)

      assert {:error, :channel_invite_not_found} =
               Memento.transaction!(fn -> ChannelInvites.get_by_user_pid_and_channel_name(pid, "#elixircd") end)
    end
  end
end
