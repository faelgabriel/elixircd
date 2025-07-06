defmodule ElixIRCd.Utils.MessageFilterTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory

  alias ElixIRCd.Utils.MessageFilter

  describe "should_silence_message?/2" do
    test "returns true when message matches silence mask exactly" do
      Memento.transaction!(fn ->
        user = insert(:user)
        source_user = insert(:user, nick: "spammer", ident: "spam", hostname: "evil.com")
        insert(:user_silence, user: user, mask: "spammer!spam@evil.com")

        result = MessageFilter.should_silence_message?(user, source_user)
        assert result == true
      end)
    end

    test "returns true when message matches wildcard silence mask" do
      Memento.transaction!(fn ->
        user = insert(:user)
        source_user = insert(:user, nick: "anyone", ident: "anything", hostname: "evil.com")
        insert(:user_silence, user: user, mask: "*!*@evil.com")

        result = MessageFilter.should_silence_message?(user, source_user)
        assert result == true
      end)
    end

    test "returns false when message does not match any silence mask" do
      Memento.transaction!(fn ->
        user = insert(:user)
        source_user = insert(:user, nick: "gooduser", ident: "good", hostname: "good.com")

        result = MessageFilter.should_silence_message?(user, source_user)
        assert result == false
      end)
    end

    test "returns false when user has no silence masks" do
      Memento.transaction!(fn ->
        user = insert(:user)
        source_user = insert(:user, nick: "anyone", ident: "anything", hostname: "anywhere.com")

        result = MessageFilter.should_silence_message?(user, source_user)
        assert result == false
      end)
    end
  end
end
