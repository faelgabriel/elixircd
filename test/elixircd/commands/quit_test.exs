defmodule ElixIRCd.Commands.QuitTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Quit
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles QUIT command" do
      user = insert(:user)
      message = %Message{command: "QUIT", params: [], trailing: "Bye!"}

      assert {:quit, "Bye!"} = Quit.handle(user, message)
    end
  end
end
