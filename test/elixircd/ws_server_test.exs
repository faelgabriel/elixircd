defmodule ElixIRCd.Server.WsListenerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Mimic

  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.WsListener

  setup :verify_on_exit!

  describe "init/1" do
    test "initializes connection with WS transport" do
      state = ws_state(:ws)

      expect(Connection, :handle_connect, fn _pid, transport, data ->
        assert transport == :ws

        assert data == %{
                 ip_address: {127, 0, 0, 1},
                 port_connected: 8080
               }

        :ok
      end)

      assert {:ok, ^state} = WsListener.init(state)
    end

    test "initializes connection with WSS transport" do
      state = ws_state(:wss)

      expect(Connection, :handle_connect, fn _pid, transport, data ->
        assert transport == :wss

        assert data == %{
                 ip_address: {127, 0, 0, 1},
                 port_connected: 8080
               }

        :ok
      end)

      assert {:ok, ^state} = WsListener.init(state)
    end
  end

  describe "handle_in/2" do
    test "processes data and continues when Connection returns :ok" do
      state = ws_state()

      expect(Connection, :handle_recv, fn _pid, data ->
        assert data == "PING :test"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({"PING :test", [opcode: :text]}, state)
    end

    test "stops connection when Connection returns quit reason" do
      state = ws_state()

      expect(Connection, :handle_recv, fn _pid, _data ->
        {:quit, "Quit: Goodbye"}
      end)

      assert {:stop, :normal, {1000, "Quit: Goodbye"}, %{quit_reason: "Quit: Goodbye"}} =
               WsListener.handle_in({"QUIT :Goodbye", [opcode: :text]}, state)
    end
  end

  describe "handle_info/2" do
    test "handles broadcast messages" do
      state = ws_state()

      assert {:push, {:text, "MESSAGE"}, ^state} =
               WsListener.handle_info({:broadcast, "MESSAGE"}, state)
    end

    test "handles disconnect messages" do
      state = ws_state()

      assert {:stop, :normal, {1000, "Client quit"}, %{quit_reason: "Client quit"}} =
               WsListener.handle_info({:disconnect, "Client quit"}, state)
    end

    test "ignores EXIT messages" do
      state = ws_state()

      assert {:ok, ^state} =
               WsListener.handle_info({:EXIT, self(), :normal}, state)
    end
  end

  describe "terminate/2" do
    test "handles normal termination with quit reason" do
      state = ws_state()
      state = Map.put(state, :quit_reason, "User quit")

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :ws
        assert reason == "User quit"
        :ok
      end)

      WsListener.terminate(:normal, state)
    end

    test "handles normal termination without quit reason" do
      state = ws_state()

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :ws
        assert reason == "Connection Closed"
        :ok
      end)

      WsListener.terminate(:normal, state)
    end

    test "handles remote termination" do
      state = ws_state()

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :ws
        assert reason == "Connection Closed"
        :ok
      end)

      WsListener.terminate(:remote, state)
    end

    test "handles error termination" do
      state = ws_state()

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :ws
        assert reason == "Connection Error"
        :ok
      end)

      WsListener.terminate({:error, :econnreset}, state)
    end

    test "handles timeout termination" do
      state = ws_state()

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :ws
        assert reason == "Connection Timeout"
        :ok
      end)

      WsListener.terminate(:timeout, state)
    end

    test "handles shutdown termination" do
      state = ws_state()

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :ws
        assert reason == "Server Shutdown"
        :ok
      end)

      WsListener.terminate(:shutdown, state)
    end
  end

  @spec ws_state(:ws | :wss) :: map()
  defp ws_state(transport \\ :ws) do
    %{
      conn: %Plug.Conn{
        remote_ip: {127, 0, 0, 1},
        port: 8080
      },
      transport: transport,
      subprotocol: nil
    }
  end
end
