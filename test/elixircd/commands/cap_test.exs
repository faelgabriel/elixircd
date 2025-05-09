defmodule ElixIRCd.Commands.CapTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Cap
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Connection

  describe "handle/2" do
    test "handles CAP command for listing supported capabilities for IRCv3.2" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP * LS\r\n"}
        ])
      end)
    end

    test "handles incompatible CAP commands" do
      Memento.transaction!(fn ->
        user = insert(:user)

        incompatible_cap_commands = [
          %Message{command: "CAP", params: ["LS", "301"]},
          %Message{command: "CAP", params: ["REQ"], trailing: "multi-prefix"},
          %Message{command: "CAP", params: ["REQ"], trailing: "multi-prefix sasl"},
          %Message{command: "CAP", params: ["REQ"], trailing: "-multi-prefix"},
          %Message{command: "CAP", params: ["REQ"], trailing: "-multi-prefix -sasl"},
          %Message{command: "CAP", params: ["END"]}
        ]

        for message <- incompatible_cap_commands do
          # Mimic the user's transport rejecting any responses since we don't support CAP yet
          Connection
          |> reject(:handle_send, 2)

          assert :ok = Cap.handle(user, message)
          verify!()
        end
      end)
    end
  end
end
