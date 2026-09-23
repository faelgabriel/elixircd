defmodule ElixIRCd.Server.S2S.ChannelListTombstonesTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelListTombstones

  test "deleting a physical list entry retains its ENP removal stamp" do
    channel = insert(:channel, name: "#tombstones")

    ban =
      Memento.transaction!(fn ->
        ChannelBans.create(%{
          channel_name_key: channel.name_key,
          mask: "*!*@example.test",
          setter: "oper"
        })
      end)

    Memento.transaction!(fn -> ChannelBans.delete(ban) end)

    tombstone =
      Memento.transaction!(fn ->
        ChannelListTombstones.get(channel.name_key, "b", ban.mask)
      end)

    assert tombstone.channel_name_key == channel.name_key
    assert tombstone.mode == "b"
    assert tombstone.mask == ban.mask
    assert tombstone.set_ms > 0
  end

  test "a newer physical entry clears an old removal stamp" do
    channel = insert(:channel, name: "#tombstone-readd")

    Memento.transaction!(fn ->
      ChannelListTombstones.put(%{
        channel_name_key: channel.name_key,
        mode: "b",
        mask: "*!*@example.test",
        set_by: "oper",
        set_ms: 1
      })

      ChannelBans.create(%{
        channel_name_key: channel.name_key,
        mask: "*!*@example.test",
        setter: "oper"
      })
    end)

    assert nil ==
             Memento.transaction!(fn ->
               ChannelListTombstones.get(channel.name_key, "b", "*!*@example.test")
             end)
  end
end
