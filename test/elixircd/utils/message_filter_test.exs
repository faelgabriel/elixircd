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

  describe "filter_auditorium_users/3" do
    test "returns all users when auditorium mode is not set" do
      Memento.transaction!(fn ->
        user1 = insert(:user)
        user2 = insert(:user)
        channel = insert(:channel, modes: [])
        uc1 = insert(:user_channel, user: user1, channel: channel, modes: [])
        uc2 = insert(:user_channel, user: user2, channel: channel, modes: [])
        actor_uc = insert(:user_channel, channel: channel, modes: [])

        result = MessageFilter.filter_auditorium_users([uc1, uc2], actor_uc, channel.modes)
        assert length(result) == 2
      end)
    end

    test "returns all users when actor is an operator" do
      Memento.transaction!(fn ->
        user1 = insert(:user)
        user2 = insert(:user)
        channel = insert(:channel, modes: ["u"])
        uc1 = insert(:user_channel, user: user1, channel: channel, modes: [])
        uc2 = insert(:user_channel, user: user2, channel: channel, modes: [])
        actor_uc = insert(:user_channel, channel: channel, modes: ["o"])

        result = MessageFilter.filter_auditorium_users([uc1, uc2], actor_uc, channel.modes)
        assert length(result) == 2
      end)
    end

    test "returns all users when actor is voiced" do
      Memento.transaction!(fn ->
        user1 = insert(:user)
        user2 = insert(:user)
        channel = insert(:channel, modes: ["u"])
        uc1 = insert(:user_channel, user: user1, channel: channel, modes: [])
        uc2 = insert(:user_channel, user: user2, channel: channel, modes: [])
        actor_uc = insert(:user_channel, channel: channel, modes: ["v"])

        result = MessageFilter.filter_auditorium_users([uc1, uc2], actor_uc, channel.modes)
        assert length(result) == 2
      end)
    end

    test "returns only ops/voiced users when auditorium mode is set and actor is normal user" do
      Memento.transaction!(fn ->
        op_user = insert(:user)
        voiced_user = insert(:user)
        normal_user = insert(:user)
        channel = insert(:channel, modes: ["u"])
        uc_op = insert(:user_channel, user: op_user, channel: channel, modes: ["o"])
        uc_voiced = insert(:user_channel, user: voiced_user, channel: channel, modes: ["v"])
        uc_normal = insert(:user_channel, user: normal_user, channel: channel, modes: [])
        actor_uc = insert(:user_channel, channel: channel, modes: [])

        result = MessageFilter.filter_auditorium_users([uc_op, uc_voiced, uc_normal], actor_uc, channel.modes)
        assert length(result) == 2
        assert uc_op in result
        assert uc_voiced in result
        refute uc_normal in result
      end)
    end

    test "handles nil actor_user_channel" do
      Memento.transaction!(fn ->
        op_user = insert(:user)
        normal_user = insert(:user)
        channel = insert(:channel, modes: ["u"])
        uc_op = insert(:user_channel, user: op_user, channel: channel, modes: ["o"])
        uc_normal = insert(:user_channel, user: normal_user, channel: channel, modes: [])

        result = MessageFilter.filter_auditorium_users([uc_op, uc_normal], nil, channel.modes)
        assert length(result) == 1
        assert uc_op in result
        refute uc_normal in result
      end)
    end
  end
end
