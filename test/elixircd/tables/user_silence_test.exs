defmodule ElixIRCd.Tables.UserSilenceTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Tables.UserSilence

  describe "new/1" do
    test "creates a new user silence with all attributes" do
      user_pid = self()
      mask = "nick!user@host.com"
      now = DateTime.utc_now()

      silence =
        UserSilence.new(%{
          user_pid: user_pid,
          mask: mask,
          created_at: now
        })

      assert silence.user_pid == user_pid
      assert silence.mask == mask
      assert silence.created_at == now
    end

    test "creates a new user silence with default created_at" do
      user_pid = self()
      mask = "nick!user@host.com"

      silence =
        UserSilence.new(%{
          user_pid: user_pid,
          mask: mask
        })

      assert silence.user_pid == user_pid
      assert silence.mask == mask
      assert %DateTime{} = silence.created_at
    end

    test "raises error when required attributes are missing" do
      assert_raise ArgumentError, fn ->
        UserSilence.new(%{mask: "nick!user@host.com"})
      end

      assert_raise ArgumentError, fn ->
        UserSilence.new(%{user_pid: self()})
      end
    end
  end
end
