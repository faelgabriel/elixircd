defmodule ElixIRCd.Tables.RegisteredNick.SettingsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "new/0" do
    test "creates a new settings struct with default values" do
      settings = Settings.new()

      assert %Settings{} = settings
      assert settings.hide_email == false
      assert settings.email_memos == :off
      assert settings.enforce == false
      assert settings.enforce_time == 0
      assert settings.hide_status == false
      assert settings.hide_usermask == false
      assert settings.hide_quit == false
      assert settings.kill == :off
      assert settings.language == "en"
      assert settings.msg == false
      assert settings.never_group == false
      assert settings.never_op == false
      assert settings.no_greet == false
      assert settings.private == false
      assert settings.property == %{}
      assert settings.pubkey == nil
      assert settings.quiet_chg == false
      assert settings.secure == false
      assert settings.url == nil
      assert settings.display == nil
    end
  end

  describe "update/2" do
    test "updates settings with map attributes" do
      settings = Settings.new()
      attrs = %{hide_email: true}

      updated_settings = Settings.update(settings, attrs)

      assert updated_settings.hide_email == true
    end

    test "updates every NickServ SET value without dropping the other values" do
      settings = Settings.new()

      updated_settings =
        Settings.update(settings, %{
          email_memos: :only,
          enforce: true,
          enforce_time: 30,
          hide_status: true,
          hide_usermask: true,
          hide_quit: true,
          kill: :immed,
          language: "pt-BR",
          msg: true,
          never_group: true,
          never_op: true,
          no_greet: true,
          private: true,
          property: %{"role" => "admin"},
          pubkey: "public-key",
          quiet_chg: true,
          secure: true,
          url: "https://example.com",
          display: "Alias"
        })

      assert updated_settings.email_memos == :only
      assert updated_settings.enforce == true
      assert updated_settings.enforce_time == 30
      assert updated_settings.hide_status == true
      assert updated_settings.hide_usermask == true
      assert updated_settings.hide_quit == true
      assert updated_settings.kill == :immed
      assert updated_settings.language == "pt-BR"
      assert updated_settings.msg == true
      assert updated_settings.never_group == true
      assert updated_settings.never_op == true
      assert updated_settings.no_greet == true
      assert updated_settings.private == true
      assert updated_settings.property == %{"role" => "admin"}
      assert updated_settings.pubkey == "public-key"
      assert updated_settings.quiet_chg == true
      assert updated_settings.secure == true
      assert updated_settings.url == "https://example.com"
      assert updated_settings.display == "Alias"
      assert updated_settings.hide_email == false
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
