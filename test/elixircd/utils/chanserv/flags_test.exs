defmodule ElixIRCd.Utils.Chanserv.FlagsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory

  alias ElixIRCd.Utils.Chanserv.Flags

  describe "normalize_flags/1" do
    test "orders flags canonically and removes duplicates" do
      assert Flags.normalize_flags("FAVFA") == "VAF"
    end
  end

  describe "access level helpers" do
    test "maps access levels to flags and back" do
      assert Flags.access_level_to_flags(3) == {:ok, "VAF"}
      assert Flags.access_level_to_flags(9) == :error
      assert Flags.flags_to_access_level("VAF") == 3
      assert Flags.flags_to_access_level("VS") == nil
    end
  end

  describe "apply_flag_changes/2" do
    test "replaces a flag set directly" do
      assert Flags.apply_flag_changes("V", "AF") == {:ok, "AF"}
    end

    test "applies incremental changes" do
      assert Flags.apply_flag_changes("V", "+AF") == {:ok, "VAF"}
      assert Flags.apply_flag_changes("VAF", "-A") == {:ok, "VF"}
    end

    test "clears flags and rejects invalid changes" do
      assert Flags.apply_flag_changes("VAF", "OFF") == {:ok, ""}
      assert Flags.apply_flag_changes("VAF", "-*") == {:ok, ""}
      assert Flags.apply_flag_changes("VAF", "") == {:ok, "VAF"}
      assert Flags.apply_flag_changes("VAF", "+Z") == {:error, :invalid_flags}
      assert Flags.apply_flag_changes("VAF", "A+") == {:error, :invalid_flags}
    end
  end

  describe "permission checks" do
    test "treats founders as having implicit full flags" do
      channel = build(:registered_channel, founder: "founder")
      access_entries = %{"helper" => "VA"}

      assert Flags.flags_for_account(channel, "founder", access_entries) == "VAFST"
      assert Flags.can_manage_access(channel, "founder", access_entries) == :ok
      assert Flags.can_manage_flags(channel, "founder", access_entries) == :ok
      assert Flags.can_use_op(channel, "founder", access_entries) == :ok
      assert Flags.can_use_voice(channel, "helper", access_entries) == :ok
      assert Flags.can_view_privileged_info(channel, "helper", access_entries) == :ok
      assert Flags.can_manage_flags(channel, "helper", access_entries) == {:error, :access_denied}
      assert Flags.can_use_op(channel, "helper", access_entries) == {:error, :access_denied}

      assert Flags.access_rank(channel, "founder", access_entries) >
               Flags.access_rank(channel, "helper", access_entries)
    end

    test "handles nil and normalizes persisted access entries" do
      channel = build(:registered_channel, founder: "founder")
      access_entries = Flags.normalize_access_entries(%{"helper" => "fvaa"})

      assert access_entries == %{"helper" => "VAF"}
      assert Flags.flags_for_account(channel, nil, access_entries) == ""
      refute Flags.founder?(channel, nil)
      assert Flags.can_view_privileged_info(channel, "guest", access_entries) == {:error, :access_denied}
      assert Flags.valid_flag_string?("VAF")
      refute Flags.valid_flag_string?("VFZ")
      assert Flags.access_rank(channel, "weird", %{"weird" => "Z"}) == 0
    end

    test "ranks broader flag sets above a lone orthogonal flag" do
      channel = build(:registered_channel, founder: "founder")

      assert Flags.access_rank(channel, "topic", %{"topic" => "T"}) <
               Flags.access_rank(channel, "staff", %{"staff" => "VAFS"})

      assert Flags.access_rank(channel, "voice", %{"voice" => "V"}) <
               Flags.access_rank(channel, "manager", %{"manager" => "VAF"})

      assert Flags.access_rank(channel, "founder", %{}) >
               Flags.access_rank(channel, "staff", %{"staff" => "VAFS"})
    end

    test "may_grant? enforces the can't-grant-what-you-lack rule" do
      channel = build(:registered_channel, founder: "founder")
      access_entries = %{"manager" => "VAF", "senior" => "VAFS"}

      assert Flags.may_grant?(channel, "manager", "", "VA", access_entries)
      assert Flags.may_grant?(channel, "manager", "V", "VAF", access_entries)
      refute Flags.may_grant?(channel, "manager", "", "VAFS", access_entries)
      refute Flags.may_grant?(channel, "manager", "VAFS", "", access_entries)
      assert Flags.may_grant?(channel, "founder", "VAFS", "VAFST", access_entries)
    end
  end
end
