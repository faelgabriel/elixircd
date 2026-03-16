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
      assert Flags.can_view_privileged_info(channel, "helper", access_entries) == :ok
      assert Flags.can_manage_flags(channel, "helper", access_entries) == {:error, :access_denied}
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
    end
  end
end
