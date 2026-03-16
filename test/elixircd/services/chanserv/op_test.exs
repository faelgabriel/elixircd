defmodule ElixIRCd.Services.Chanserv.OpTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Mode.Command
  alias ElixIRCd.Services.Chanserv.Op

  describe "handle/2" do
    test "delegates to the shared mode command helper" do
      Memento.transaction!(fn ->
        user = insert(:user)
        args = ["#channel", "TargetNick"]

        Command
        |> expect(:handle, fn input_user, command_name, input_args, permission_kind, action ->
          assert input_user == user
          assert command_name == "OP"
          assert input_args == args
          assert permission_kind == :op
          assert action == :add
          :ok
        end)

        assert :ok = Op.handle(user, ["OP" | args])
      end)
    end
  end
end
