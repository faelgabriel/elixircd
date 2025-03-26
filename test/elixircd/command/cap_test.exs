defmodule ElixIRCd.Command.CapTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Command.Cap
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging

  describe "handle/2" do
    test "handles CAP command for listing supported capabilities for IRCv3.2" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com CAP * LS\r\n"}
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
          Messaging
          |> reject(:send_message, 2)

          assert :ok = Cap.handle(user, message)
          verify!()
        end
      end)
    end
  end
end
