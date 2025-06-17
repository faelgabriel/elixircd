defmodule ElixIRCd.Utils.CaseMappingTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  alias ElixIRCd.Utils.CaseMapping

  describe "normalize/1" do
    setup do
      original_settings = Application.get_env(:elixircd, :settings)
      on_exit(fn -> Application.put_env(:elixircd, :settings, original_settings) end)
      {:ok, original_settings: original_settings}
    end

    test "normalizes with ascii case mapping", %{original_settings: original_settings} do
      settings = Keyword.put(original_settings, :case_mapping, :ascii)
      Application.put_env(:elixircd, :settings, settings)

      assert CaseMapping.normalize("ABC") == "abc"
      assert CaseMapping.normalize("XyZ") == "xyz"
      assert CaseMapping.normalize("{|}~") == "{|}~"
    end

    test "normalizes with rfc1459 case mapping", %{original_settings: original_settings} do
      settings = Keyword.put(original_settings, :case_mapping, :rfc1459)
      Application.put_env(:elixircd, :settings, settings)

      assert CaseMapping.normalize("ABC") == "abc"
      assert CaseMapping.normalize("XyZ") == "xyz"
      assert CaseMapping.normalize("{|}~") == "[\\]^"
      assert CaseMapping.normalize("test{channel}") == "test[channel]"
    end

    test "normalizes with strict_rfc1459 case mapping", %{original_settings: original_settings} do
      settings = Keyword.put(original_settings, :case_mapping, :strict_rfc1459)
      Application.put_env(:elixircd, :settings, settings)

      assert CaseMapping.normalize("ABC") == "abc"
      assert CaseMapping.normalize("XyZ") == "xyz"
      assert CaseMapping.normalize("{|}") == "[\\]"
      assert CaseMapping.normalize("{|}~") == "[\\]~"
      assert CaseMapping.normalize("test{channel}") == "test[channel]"
    end

    test "uses configured case mapping by default", %{original_settings: original_settings} do
      settings = Keyword.put(original_settings, :case_mapping, :rfc1459)
      Application.put_env(:elixircd, :settings, settings)

      assert CaseMapping.normalize("{|}~") == "[\\]^"
    end
  end
end
