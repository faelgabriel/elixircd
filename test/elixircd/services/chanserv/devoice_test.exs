defmodule ElixIRCd.Services.Chanserv.DevoiceTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Devoice
  alias ElixIRCd.Services.Chanserv.Mode.Command

  describe "handle/2" do
    test "delegates to the shared mode command helper" do
      Memento.transaction!(fn ->
        user = insert(:user)
        args = ["#channel", "TargetNick"]

        Command
        |> expect(:handle, fn input_user, command_name, input_args, permission_kind, action ->
          assert input_user == user
          assert command_name == "DEVOICE"
          assert input_args == args
          assert permission_kind == :voice
          assert action == :remove
          :ok
        end)

        assert :ok = Devoice.handle(user, ["DEVOICE" | args])
      end)
    end
  end
end
