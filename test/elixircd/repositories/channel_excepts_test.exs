defmodule ElixIRCd.Repositories.ChannelExceptsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Tables.ChannelExcept

  describe "create/1" do
    test "creates a new channel except" do
      attrs = %{
        channel_name_key: "#elixircd",
        mask: "user!user@host",
        setter: "setter!setter@host"
      }

      channel_except = Memento.transaction!(fn -> ChannelExcepts.create(attrs) end)

      assert channel_except.channel_name_key == "#elixircd"
      assert channel_except.mask == "user!user@host"
      assert channel_except.setter == "setter!setter@host"
    end
  end

  describe "delete/1" do
    test "deletes a channel except" do
      channel_except = insert(:channel_except)
      Memento.transaction!(fn -> ChannelExcepts.delete(channel_except) end)
      assert nil == Memento.transaction!(fn -> Memento.Query.read(ChannelExcept, channel_except.channel_name_key) end)
    end
  end

  describe "get_by_channel_name_key/1" do
    test "gets channel excepts by the channel name" do
      channel_except = insert(:channel_except)

      assert [%ChannelExcept{}] =
               Memento.transaction!(fn -> ChannelExcepts.get_by_channel_name_key(channel_except.channel_name_key) end)
    end
  end

  describe "get_by_channel_name_key_and_mask/2" do
    test "gets a channel except by the channel name key and mask" do
      channel_except = insert(:channel_except)

      assert {:ok, %ChannelExcept{}} =
               Memento.transaction!(fn ->
                 ChannelExcepts.get_by_channel_name_key_and_mask(channel_except.channel_name_key, channel_except.mask)
               end)
    end

    test "returns an error when the channel except is not found" do
      assert {:error, :channel_except_not_found} =
               Memento.transaction!(fn ->
                 ChannelExcepts.get_by_channel_name_key_and_mask("#elixircd", "user!user@host")
               end)
    end
  end
end
