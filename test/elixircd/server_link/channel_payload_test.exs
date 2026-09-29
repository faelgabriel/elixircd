defmodule ElixIRCd.ServerLink.ChannelPayloadTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.Factory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.Channel.Topic

  test "local channel, membership, list and invite become bounded PID-free records" do
    now = DateTime.utc_now()

    channel =
      Factory.build(:channel,
        name: "#rooms",
        modes: [:n, {:k, "secret"}],
        topic: %Topic{text: "Hello", setter: "Alice", set_at: now}
      )

    member = Factory.build(:user_channel, channel_name_key: channel.name_key, modes: [:o])
    ban = Factory.build(:channel_ban, channel_name_key: channel.name_key, mask: "*!*@example.test")
    invite = Factory.build(:channel_invite, channel_name_key: channel.name_key)
    uid = UserPayload.new_uid()

    metadata = ChannelPayload.from_local(channel)
    membership = ChannelPayload.member_from_local(member, channel.name, uid)
    list_entry = ChannelPayload.list_from_local(ban, channel.name, "b")
    invitation = ChannelPayload.invite_from_local(invite, channel.name, uid)

    assert :ok = ChannelPayload.validate_channel(metadata)
    assert :ok = ChannelPayload.validate_member(membership)
    assert :ok = ChannelPayload.validate_list(list_entry)
    assert :ok = ChannelPayload.validate_invite(invitation)
    refute inspect({metadata, membership, list_entry, invitation}) =~ "#PID"
  end

  test "rejects malformed names, modes, references and control bytes" do
    channel = Factory.build(:channel, name: "#room") |> ChannelPayload.from_local()
    uid = UserPayload.new_uid()
    member = Factory.build(:user_channel) |> ChannelPayload.member_from_local("#room", uid)
    ban = Factory.build(:channel_ban) |> ChannelPayload.list_from_local("#room", "b")
    invite = Factory.build(:channel_invite) |> ChannelPayload.invite_from_local("#room", uid)

    assert {:error, :invalid_channel} = ChannelPayload.validate_channel(%{channel | "name" => "&local"})
    assert {:error, :invalid_channel} = ChannelPayload.validate_channel(%{channel | "creator" => "Bad Host"})

    assert {:error, :invalid_channel} =
             ChannelPayload.validate_channel(%{channel | "modes" => [%{"name" => "o", "parameter" => nil}]})

    assert {:error, :invalid_member} = ChannelPayload.validate_member(%{member | "uid" => "bad"})
    assert {:error, :invalid_list} = ChannelPayload.validate_list(%{ban | "mask" => "bad\r\n"})
    assert {:error, :invalid_invite} = ChannelPayload.validate_invite(%{invite | "bypass_ban" => "yes"})
  end
end
