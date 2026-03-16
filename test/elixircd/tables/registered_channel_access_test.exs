defmodule ElixIRCd.Tables.RegisteredChannelAccessTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.RegisteredChannelAccess

  describe "new/1" do
    test "normalizes keys and builds the composite id" do
      access =
        RegisteredChannelAccess.new(%{
          channel_name: "#TestChannel",
          account_name: "Helper",
          flags: "vaf"
        })

      assert access.id == {"#testchannel", "helper"}
      assert access.channel_name_key == "#testchannel"
      assert access.account_name_key == "helper"
      assert access.account_name == "Helper"
      assert access.flags == "VAF"
      assert %DateTime{} = access.created_at
    end

    test "preserves explicit normalized keys" do
      timestamp = DateTime.utc_now()

      access =
        RegisteredChannelAccess.new(%{
          channel_name_key: "#testchannel",
          account_name_key: "helper",
          account_name: "helper",
          flags: "VA",
          created_at: timestamp
        })

      assert access.id == {"#testchannel", "helper"}
      assert access.created_at == timestamp
    end

    test "raises when required keys cannot be derived" do
      assert_raise FunctionClauseError, fn ->
        RegisteredChannelAccess.new(%{flags: "VA"})
      end
    end
  end
end
