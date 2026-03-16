defmodule ElixIRCd.Services.Chanserv.DeopTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Deop
  alias ElixIRCd.Services.Chanserv.Mode.Command

  describe "handle/2" do
    test "delegates to the shared mode command helper" do
      Memento.transaction!(fn ->
        user = insert(:user)
        args = ["#channel", "TargetNick"]

        Command
        |> expect(:handle, fn input_user, command_name, input_args, permission_kind, action ->
          assert input_user == user
          assert command_name == "DEOP"
          assert input_args == args
          assert permission_kind == :op
          assert action == :remove
          :ok
        end)

        assert :ok = Deop.handle(user, ["DEOP" | args])
      end)
    end
  end
end
