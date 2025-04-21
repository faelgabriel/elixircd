defmodule ElixIRCd.Tables.RegisteredChannel.SettingsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.RegisteredChannel.Settings

  describe "new/0" do
    test "creates a new settings struct with default values" do
      settings = Settings.new()

      assert %Settings{} = settings
      assert settings.keeptopic == true
      assert settings.op_notice == true
      assert settings.peace == false
      assert settings.private == false
      assert settings.restricted == false
      assert settings.secure == false
      assert settings.fantasy == true
      assert settings.guard == true
      assert settings.topiclock == false
      assert is_nil(settings.description)
      assert is_nil(settings.url)
      assert is_nil(settings.email)
      assert is_nil(settings.entry_message)
      assert is_nil(settings.persistent_topic)
    end
  end

  describe "update/2" do
    test "updates settings with map attributes" do
      settings = Settings.new()
      attrs = %{private: true, description: "Test channel"}

      updated_settings = Settings.update(settings, attrs)

      assert updated_settings.private == true
      assert updated_settings.description == "Test channel"
    end

    test "updates settings with keyword list attributes" do
      settings = Settings.new()
      attrs = [restricted: true, entry_message: "Welcome!"]

      updated_settings = Settings.update(settings, attrs)

      assert updated_settings.restricted == true
      assert updated_settings.entry_message == "Welcome!"
    end

    test "preserves existing values when not specified in update" do
      settings = %Settings{keeptopic: true, op_notice: false}
      attrs = %{private: true}

      updated_settings = Settings.update(settings, attrs)

      assert updated_settings.keeptopic == true
      assert updated_settings.op_notice == false
      assert updated_settings.private == true
    end
  end
end
