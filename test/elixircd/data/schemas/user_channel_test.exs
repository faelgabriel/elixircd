defmodule ElixIRCd.Data.Schemas.UserChannelTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Data.Schemas.UserChannel

  alias ElixIRCd.Data.Schemas.UserChannel

  import ElixIRCd.Factory

  describe "changeset/2" do
    setup do
      user_channel = build(:user_channel)

      {:ok, user_channel: user_channel}
    end

    test "validates required fields", %{user_channel: user_channel} do
      changeset = UserChannel.changeset(user_channel, %{})
      assert changeset.valid? == false
      assert changeset.errors[:user_socket] == {"can't be blank", [validation: :required]}
      assert changeset.errors[:channel_name] == {"can't be blank", [validation: :required]}
    end

    test "validates modes", %{user_channel: user_channel} do
      changeset = UserChannel.changeset(user_channel, %{modes: [a: 1]})
      assert changeset.valid? == false
      assert changeset.errors[:modes] == {"Invalid user channel modes: [a: 1]", []}
    end

    test "creates a valid changeset", %{user_channel: user_channel} do
      user = build(:user)

      changeset = UserChannel.changeset(user_channel, %{user_socket: user.socket, channel_name: "channel1"})
      assert changeset.valid? == true
      assert changeset.errors[:user_socket] == nil
      assert changeset.errors[:channel_name] == nil
    end
  end
end
