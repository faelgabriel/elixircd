defmodule ElixIRCd.Utils.NetworkTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Utils.Network

  describe "lookup_hostname/1" do
    test "gets hostname from an ipv4 address" do
      assert {:ok, _hostname} = Network.lookup_hostname({127, 0, 0, 1})
    end

    test "gets hostname from an ipv6 address" do
      assert {:ok, _hostname} = Network.lookup_hostname({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "returns error for invalid address" do
      assert {:error, "Unable to get hostname for {300, 0, 0, 0}: :einval"} ==
               Network.lookup_hostname({300, 0, 0, 0})

      assert {:error, "Unable to get hostname for {999, 0, 0, 0, 0, 0, 0}: :einval"} ==
               Network.lookup_hostname({999, 0, 0, 0, 0, 0, 0})
    end
  end

  describe "format_ip_address/1" do
    test "formats ipv4 address" do
      assert "127.0.0.1" = Network.format_ip_address({127, 0, 0, 1})
    end

    test "formats ipv6 address" do
      assert "::1" = Network.format_ip_address({0, 0, 0, 0, 0, 0, 0, 1})
    end
  end

  describe "ident protocol" do
    test "uses the remote IRC client port followed by the local IRC server port" do
      assert Network.format_ident_query(54_321, 6667) == "54321, 6667\r\n"
    end

    test "accepts a matching, valid USERID response" do
      assert Network.parse_ident_response("54321, 6667 : USERID : UNIX : alice\r\n", 54_321, 6667) ==
               {:ok, "alice"}
    end

    test "rejects a response for another connection or with unsafe identity characters" do
      assert {:error, _} = Network.parse_ident_response("54322, 6667 : USERID : UNIX : alice\r\n", 54_321, 6667)
      assert {:error, _} = Network.parse_ident_response("54321, 6667 : USERID : UNIX : alice!evil\r\n", 54_321, 6667)

      assert {:error, _} =
               Network.parse_ident_response("54321, 6667 : USERID : UNIX : alice\r\nNOTICE x\r\n", 54_321, 6667)

      assert {:error, _} = Network.parse_ident_response("54321, 6667 : USERID : UNIX : longidentity\r\n", 54_321, 6667)
    end
  end
end
