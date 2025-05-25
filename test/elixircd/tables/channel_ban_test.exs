defmodule ElixIRCd.Tables.ChannelBanTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.ChannelBan

  describe "new/1" do
    test "creates a new channel ban with default values" do
      attrs = %{
        channel_name_key: "#test",
        mask: "*!*@example.com",
        setter: "setter_nick!username@example.com"
      }

      channel_ban = ChannelBan.new(attrs)

      assert channel_ban.channel_name_key == "#test"
      assert channel_ban.mask == "*!*@example.com"
      assert channel_ban.setter == "setter_nick!username@example.com"
      assert DateTime.diff(DateTime.utc_now(), channel_ban.created_at) < 1000
    end

    test "creates a new channel ban with custom values" do
      utc_now = DateTime.utc_now()

      attrs = %{
        channel_name_key: "#test",
        mask: "*!*@example.com",
        setter: "setter_nick!username@example.com",
        created_at: utc_now
      }

      channel_ban = ChannelBan.new(attrs)

      assert channel_ban.channel_name_key == "#test"
      assert channel_ban.mask == "*!*@example.com"
      assert channel_ban.setter == "setter_nick!username@example.com"
      assert channel_ban.created_at == utc_now
    end
  end
end
