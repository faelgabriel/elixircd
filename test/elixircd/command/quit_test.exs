defmodule ElixIRCd.Command.QuitTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  doctest ElixIRCd.Command.Quit

  alias ElixIRCd.Command.Quit
  alias ElixIRCd.Message

  import ElixIRCd.Factory

  describe "handle/2" do
    test "handles QUIT command" do
      %{socket: user_socket} = user = insert(:user)
      message = %Message{command: "QUIT", params: [], body: "Bye!"}

      Quit.handle(user, message)

      assert_received {:user_quit, ^user_socket, "Bye!"}
    end
  end
end
