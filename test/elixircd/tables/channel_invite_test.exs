defmodule ElixIRCd.Tables.ChannelInviteTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.ChannelInvite

  describe "new/1" do
    test "creates a new channel invite with default values" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      attrs = %{
        channel_name: "#test",
        user_port: port,
        setter: "setter_nick!username@example.com"
      }

      channel_invite = ChannelInvite.new(attrs)

      assert channel_invite.channel_name == "#test"
      assert channel_invite.user_port == port
      assert channel_invite.setter == "setter_nick!username@example.com"
      assert DateTime.diff(DateTime.utc_now(), channel_invite.created_at) < 1000
    end

    test "creates a new channel invite with custom values" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])
      utc_now = DateTime.utc_now()

      attrs = %{
        channel_name: "#test",
        user_port: port,
        setter: "setter_nick!username@example.com",
        created_at: utc_now
      }

      channel_invite = ChannelInvite.new(attrs)

      assert channel_invite.channel_name == "#test"
      assert channel_invite.user_port == port
      assert channel_invite.setter == "setter_nick!username@example.com"
      assert channel_invite.created_at == utc_now
    end
  end
end
