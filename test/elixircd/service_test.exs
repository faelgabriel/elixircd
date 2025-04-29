defmodule ElixIRCd.ServiceTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Service
  alias ElixIRCd.Services.Nickserv

  describe "service_implemented?/1" do
    test "returns true for implemented services" do
      assert Service.service_implemented?("nickserv") == true
      assert Service.service_implemented?("chanserv") == true
    end

    test "returns false for non-implemented services" do
      assert Service.service_implemented?("anything") == false
    end
  end

  describe "dispatch/3" do
    setup do
      user = build(:user)
      {:ok, user: user}
    end

    test "dispatches command to the appropriate service module", %{user: user} do
      command_list = ["REGISTER", "password", "email@example.com"]

      Nickserv
      |> expect(:handle, fn input_user, input_command_list ->
        assert input_user == user
        assert input_command_list == command_list
        :ok
      end)

      assert :ok = Service.dispatch(user, "NICKSERV", command_list)
    end

    test "dispatches command with case-insensitive service name", %{user: user} do
      command_list = ["REGISTER", "password", "email@example.com"]

      Nickserv
      |> expect(:handle, fn input_user, input_command_list ->
        assert input_user == user
        assert input_command_list == command_list
        :ok
      end)

      assert :ok = Service.dispatch(user, "nickserv", command_list)
    end

    test "raises error when dispatching to non-existent service", %{user: user} do
      command_list = ["REGISTER", "password", "email@example.com"]

      assert_raise KeyError, fn ->
        Service.dispatch(user, "INVALID", command_list)
      end
    end
  end
end
