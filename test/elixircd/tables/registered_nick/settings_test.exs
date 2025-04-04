defmodule ElixIRCd.Tables.RegisteredNick.SettingsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "new/0" do
    test "creates a new settings struct with default values" do
      settings = Settings.new()

      assert %Settings{} = settings
      assert settings.hide_email == false
    end
  end

  describe "update/2" do
    test "updates settings with map attributes" do
      settings = Settings.new()
      attrs = %{hide_email: true}

      updated_settings = Settings.update(settings, attrs)

      assert updated_settings.hide_email == true
    end

    test "updates settings with keyword list attributes" do
      settings = Settings.new()
      attrs = [hide_email: true]

      updated_settings = Settings.update(settings, attrs)

      assert updated_settings.hide_email == true
    end

    test "preserves existing values when not specified in update" do
      settings = %Settings{hide_email: false}
      attrs = %{}

      updated_settings = Settings.update(settings, attrs)

      assert updated_settings.hide_email == false
    end
  end
end
