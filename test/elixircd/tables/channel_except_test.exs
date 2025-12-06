defmodule ElixIRCd.Tables.ChannelExceptTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Tables.ChannelExcept

  describe "new/1" do
    test "creates a new channel except" do
      attrs = %{
        channel_name_key: "#elixircd",
        mask: "user!user@host",
        setter: "setter!setter@host"
      }

      channel_except = ChannelExcept.new(attrs)

      assert channel_except.channel_name_key == "#elixircd"
      assert channel_except.mask == "user!user@host"
      assert channel_except.setter == "setter!setter@host"
      assert %DateTime{} = channel_except.created_at
    end

    test "creates a new channel except with created_at" do
      created_at = DateTime.utc_now()

      attrs = %{
        channel_name_key: "#elixircd",
        mask: "user!user@host",
        setter: "setter!setter@host",
        created_at: created_at
      }

      channel_except = ChannelExcept.new(attrs)

      assert channel_except.created_at == created_at
    end
  end
end
