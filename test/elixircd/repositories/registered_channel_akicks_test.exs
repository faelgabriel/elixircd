defmodule ElixIRCd.Repositories.RegisteredChannelAkicksTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Repositories.RegisteredChannelAkicks
  alias ElixIRCd.Tables.RegisteredChannelAkick

  test "renames channel entries and deletes account entries without touching masks" do
    Memento.transaction!(fn ->
      account = RegisteredChannelAkick.new("#old", :account, "Owner", nil, "Founder")
      mask = RegisteredChannelAkick.new("#old", :mask, "*!*@example.test", nil, "Founder")
      RegisteredChannelAkicks.put(account)
      RegisteredChannelAkicks.put(mask)

      assert :ok = RegisteredChannelAkicks.rename("#old", "#new")
      assert RegisteredChannelAkicks.list("#old") == []
      assert length(RegisteredChannelAkicks.list("#new")) == 2
      assert %{target: "Owner"} = RegisteredChannelAkicks.get("#new", :account, "Owner")

      assert :ok = RegisteredChannelAkicks.delete_by_account("Owner")
      assert RegisteredChannelAkicks.get("#new", :account, "Owner") == nil
      assert %{kind: :mask} = RegisteredChannelAkicks.get("#new", :mask, "*!*@example.test")
    end)
  end
end
