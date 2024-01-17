defmodule ElixIRCd.Command.CapTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  doctest ElixIRCd.Command.Cap

  alias ElixIRCd.Command.Cap
  alias ElixIRCd.Message

  import ElixIRCd.Factory
  import Mimic

  describe "handle/2" do
    test "handles CAP command for listing supported capabilities for IRCv3.2" do
      user = insert(:user, identity: nil)
      message = %Message{command: "CAP", params: ["LS", "302"]}

      Cap.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com CAP * LS\r\n"}
      ])
    end

    test "handles incompatible CAP commands" do
      user = insert(:user)

      incompatible_cap_commands = [
        %Message{command: "CAP", params: ["LS", "301"]},
        %Message{command: "CAP", params: ["REQ"], body: "multi-prefix"},
        %Message{command: "CAP", params: ["REQ"], body: "multi-prefix sasl"},
        %Message{command: "CAP", params: ["REQ"], body: "-multi-prefix"},
        %Message{command: "CAP", params: ["REQ"], body: "-multi-prefix -sasl"},
        %Message{command: "CAP", params: ["END"]}
      ]

      for message <- incompatible_cap_commands do
        # Mimic the user's transport rejecting any responses since we don't support CAP yet
        user.transport
        |> reject(:send, 2)

        Cap.handle(user, message)
        verify!()
      end
    end
  end
end
