defmodule ElixIRCd.Tables.ChannelInviteTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.ChannelInvite

  describe "new/1" do
    test "creates a new channel invite with default values" do
      pid = spawn(fn -> :ok end)

      attrs = %{
        user_pid: pid,
        channel_name: "#test",
        setter: "setter_nick!username@example.com"
      }

      channel_invite = ChannelInvite.new(attrs)

      assert channel_invite.user_pid == pid
      assert channel_invite.channel_name == "#test"
      assert channel_invite.setter == "setter_nick!username@example.com"
      assert DateTime.diff(DateTime.utc_now(), channel_invite.created_at) < 1000
    end

    test "creates a new channel invite with custom values" do
      pid = spawn(fn -> :ok end)
      utc_now = DateTime.utc_now()

      attrs = %{
        user_pid: pid,
        channel_name: "#test",
        setter: "setter_nick!username@example.com",
        created_at: utc_now
      }

      channel_invite = ChannelInvite.new(attrs)

      assert channel_invite.user_pid == pid
      assert channel_invite.channel_name == "#test"
      assert channel_invite.setter == "setter_nick!username@example.com"
      assert channel_invite.created_at == utc_now
    end
  end
end
