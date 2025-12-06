defmodule ElixIRCd.Tables.ChannelInvexTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Tables.ChannelInvex

  describe "new/1" do
    test "creates a new channel invex" do
      attrs = %{
        channel_name_key: "#elixircd",
        mask: "user!user@host",
        setter: "setter!setter@host"
      }

      channel_invex = ChannelInvex.new(attrs)

      assert channel_invex.channel_name_key == "#elixircd"
      assert channel_invex.mask == "user!user@host"
      assert channel_invex.setter == "setter!setter@host"
      assert %DateTime{} = channel_invex.created_at
    end

    test "creates a new channel invex with created_at" do
      created_at = DateTime.utc_now()

      attrs = %{
        channel_name_key: "#elixircd",
        mask: "user!user@host",
        setter: "setter!setter@host",
        created_at: created_at
      }

      channel_invex = ChannelInvex.new(attrs)

      assert channel_invex.created_at == created_at
    end
  end
end
