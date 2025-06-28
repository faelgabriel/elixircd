defmodule ElixIRCd.Utils.FormattingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Utils.Formatting

  describe "contains_formatting?/1" do
    test "returns false for plain text" do
      assert Formatting.contains_formatting?("Hello world") == false
    end

    test "returns true for messages containing color codes" do
      assert Formatting.contains_formatting?("\x03Hello world") == true
      assert Formatting.contains_formatting?("Hello \x03red world") == true
    end

    test "returns true for messages containing color codes with parameters" do
      assert Formatting.contains_formatting?("\x0304Hello world") == true
      assert Formatting.contains_formatting?("\x031,2Hello world") == true
      assert Formatting.contains_formatting?("\x0304,08Hello world") == true
    end

    test "returns true for messages containing bold codes" do
      assert Formatting.contains_formatting?("\x02Bold text\x02") == true
      assert Formatting.contains_formatting?("Some \x02bold\x02 text") == true
    end

    test "returns true for messages containing underline codes" do
      assert Formatting.contains_formatting?("\x1FUnderlined text\x1F") == true
      assert Formatting.contains_formatting?("Some \x1Funderlined\x1F text") == true
    end

    test "returns true for messages containing reverse codes" do
      assert Formatting.contains_formatting?("\x16Reversed text\x16") == true
      assert Formatting.contains_formatting?("Some \x16reversed\x16 text") == true
    end

    test "returns true for messages containing italic codes" do
      assert Formatting.contains_formatting?("\x1DItalic text\x1D") == true
      assert Formatting.contains_formatting?("Some \x1Ditalic\x1D text") == true
    end

    test "returns true for messages containing strikethrough codes" do
      assert Formatting.contains_formatting?("\x1EStrikethrough text\x1E") == true
      assert Formatting.contains_formatting?("Some \x1Estrikethrough\x1E text") == true
    end

    test "returns true for messages containing monospace codes" do
      assert Formatting.contains_formatting?("\x11Monospace text\x11") == true
      assert Formatting.contains_formatting?("Some \x11monospace\x11 text") == true
    end

    test "returns true for messages containing multiple formatting codes" do
      assert Formatting.contains_formatting?("\x02\x03Bold and colored\x0F") == true
      assert Formatting.contains_formatting?("\x1F\x1DUnderlined and italic\x0F") == true
    end

    test "returns true for messages containing reset codes" do
      assert Formatting.contains_formatting?("Some text\x0F") == true
      assert Formatting.contains_formatting?("\x0FReset at start") == true
    end

    test "returns false for empty string" do
      assert Formatting.contains_formatting?("") == false
    end
  end

  describe "ctcp_message?/1" do
    test "returns true for valid CTCP messages" do
      assert Formatting.ctcp_message?("\x01VERSION\x01") == true
      assert Formatting.ctcp_message?("\x01PING 1234567890\x01") == true
      assert Formatting.ctcp_message?("\x01ACTION does something\x01") == true
      assert Formatting.ctcp_message?("\x01CLIENTINFO\x01") == true
    end

    test "returns false for non-CTCP messages" do
      assert Formatting.ctcp_message?("Hello world") == false
      assert Formatting.ctcp_message?("VERSION") == false
      assert Formatting.ctcp_message?("PING 1234567890") == false
    end

    test "returns false for messages that only start with CTCP delimiter" do
      assert Formatting.ctcp_message?("\x01VERSION") == false
      assert Formatting.ctcp_message?("\x01PING 1234567890") == false
    end

    test "returns false for messages that only end with CTCP delimiter" do
      assert Formatting.ctcp_message?("VERSION\x01") == false
      assert Formatting.ctcp_message?("PING 1234567890\x01") == false
    end

    test "returns false for empty string" do
      assert Formatting.ctcp_message?("") == false
    end

    test "returns true for string with only CTCP delimiters" do
      assert Formatting.ctcp_message?("\x01\x01") == true
    end
  end
end
