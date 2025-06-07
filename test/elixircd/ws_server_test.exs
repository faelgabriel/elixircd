defmodule ElixIRCd.Server.WsListenerTest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.WsListener

  describe "init/1" do
    test "initializes connection with WS transport" do
      state = ws_state(:ws)

      expect(Connection, :handle_connect, fn _pid, transport, data ->
        assert transport == :ws
        assert data == %{ip_address: {127, 0, 0, 1}, port_connected: 8080}
        :ok
      end)

      assert {:ok, ^state} = WsListener.init(state)
    end

    test "initializes connection with WSS transport" do
      state = ws_state(:wss)

      expect(Connection, :handle_connect, fn _pid, transport, data ->
        assert transport == :wss
        assert data == %{ip_address: {127, 0, 0, 1}, port_connected: 8080}
        :ok
      end)

      assert {:ok, ^state} = WsListener.init(state)
    end

    test "stops connection when Connection returns :close" do
      state = ws_state(:ws)

      expect(Connection, :handle_connect, fn _pid, transport, data ->
        assert transport == :ws
        assert data == %{ip_address: {127, 0, 0, 1}, port_connected: 8080}
        :close
      end)

      assert {:stop, :normal, ^state} = WsListener.init(state)
    end
  end

  describe "handle_in/2" do
    test "processes data and continues when Connection returns :ok" do
      state = ws_state()

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == "PING :test"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({"PING :test", [opcode: :text]}, state)
    end

    test "stops connection when Connection returns quit reason" do
      state = ws_state()

      expect(Connection, :handle_receive, fn _pid, _data ->
        {:quit, "Quit: Goodbye"}
      end)

      assert {:stop, :normal, {1000, "Quit: Goodbye"}, %{quit_reason: "Quit: Goodbye"}} =
               WsListener.handle_in({"QUIT :Goodbye", [opcode: :text]}, state)
    end

    test "handles text frames with text.ircv3.net subprotocol" do
      state = ws_state(:ws, "text.ircv3.net")

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == "PRIVMSG #test :hello"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({"PRIVMSG #test :hello", [opcode: :text]}, state)
    end

    test "handles binary frames with binary.ircv3.net subprotocol" do
      state = ws_state(:ws, "binary.ircv3.net")

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == "PRIVMSG #test :hello"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({"PRIVMSG #test :hello", [opcode: :binary]}, state)
    end

    test "handles mismatched frame type for text.ircv3.net" do
      state = ws_state(:ws, "text.ircv3.net")

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == "PRIVMSG #test :hello"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({"PRIVMSG #test :hello", [opcode: :binary]}, state)
    end

    test "handles mismatched frame type for binary.ircv3.net" do
      state = ws_state(:ws, "binary.ircv3.net")

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == "PRIVMSG #test :hello"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({"PRIVMSG #test :hello", [opcode: :text]}, state)
    end

    test "handles invalid UTF-8 in text frames when utf8_only is disabled" do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: false))

      state = ws_state(:ws, "text.ircv3.net")
      invalid_utf8 = "PRIVMSG #test :hello" <> <<0xFF, 0xFE>>

      expect(Connection, :handle_receive, fn _pid, data ->
        assert String.valid?(data)
        assert data == "PRIVMSG #test :hello��"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({invalid_utf8, [opcode: :text]}, state)

      Application.put_env(:elixircd, :settings, original_settings)
    end

    test "passes through invalid UTF-8 in text frames when utf8_only is enabled" do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: true))

      state = ws_state(:ws, "text.ircv3.net")
      invalid_utf8 = "PRIVMSG #test :hello" <> <<0xFF, 0xFE>>

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == invalid_utf8
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({invalid_utf8, [opcode: :text]}, state)

      Application.put_env(:elixircd, :settings, original_settings)
    end

    test "handles no subprotocol with text frame" do
      state = ws_state(:ws, nil)

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == "PRIVMSG #test :hello"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({"PRIVMSG #test :hello", [opcode: :text]}, state)
    end

    test "handles no subprotocol with binary frame" do
      state = ws_state(:ws, nil)

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == "PRIVMSG #test :hello"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({"PRIVMSG #test :hello", [opcode: :binary]}, state)
    end

    test "preserves valid UTF-8 strings in incoming messages" do
      state = ws_state(:ws, "text.ircv3.net")
      valid_utf8 = "PRIVMSG #test :Hello 世界 🌍"

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == valid_utf8
        assert String.valid?(data)
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({valid_utf8, [opcode: :text]}, state)
    end

    test "replaces invalid UTF-8 sequences in incoming messages when utf8_only is disabled" do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: false))

      state = ws_state(:ws, "text.ircv3.net")
      invalid_utf8 = "PRIVMSG #test :hello" <> <<0xFF>> <> "world" <> <<0xFE, 0xFD>>

      expect(Connection, :handle_receive, fn _pid, data ->
        assert String.valid?(data)
        assert data == "PRIVMSG #test :hello�world��"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({invalid_utf8, [opcode: :text]}, state)

      Application.put_env(:elixircd, :settings, original_settings)
    end

    test "covers replace_invalid_utf8 path with valid multi-byte UTF-8 after invalid byte" do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: false))

      state = ws_state(:ws, "text.ircv3.net")
      sequence_with_valid_multibyte = <<0xFF, 0xE4, 0xB8, 0x96>>

      expect(Connection, :handle_receive, fn _pid, data ->
        assert String.valid?(data)
        assert data == "�世"
        :ok
      end)

      assert {:ok, ^state} = WsListener.handle_in({sequence_with_valid_multibyte, [opcode: :text]}, state)

      Application.put_env(:elixircd, :settings, original_settings)
    end
  end

  describe "handle_info/2" do
    test "handles broadcast messages with no subprotocol (defaults to text)" do
      state = ws_state()

      assert {:push, {:text, "MESSAGE"}, ^state} = WsListener.handle_info({:broadcast, "MESSAGE"}, state)
    end

    test "handles broadcast messages with text.ircv3.net subprotocol" do
      state = ws_state(:ws, "text.ircv3.net")

      assert {:push, {:text, "MESSAGE"}, ^state} = WsListener.handle_info({:broadcast, "MESSAGE"}, state)
    end

    test "handles broadcast messages with binary.ircv3.net subprotocol" do
      state = ws_state(:ws, "binary.ircv3.net")

      assert {:push, {:binary, "MESSAGE"}, ^state} = WsListener.handle_info({:broadcast, "MESSAGE"}, state)
    end

    test "sanitizes invalid UTF-8 in text frames when utf8_only is disabled" do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: false))

      state = ws_state(:ws, "text.ircv3.net")
      invalid_utf8 = "MESSAGE" <> <<0xFF, 0xFE>>

      {:push, {:text, result}, ^state} = WsListener.handle_info({:broadcast, invalid_utf8}, state)

      assert String.valid?(result)
      assert result == "MESSAGE��"

      Application.put_env(:elixircd, :settings, original_settings)
    end

    test "passes through invalid UTF-8 in text frames when utf8_only is enabled" do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: true))

      state = ws_state(:ws, "text.ircv3.net")
      invalid_utf8 = "MESSAGE" <> <<0xFF, 0xFE>>

      {:push, {:text, result}, ^state} = WsListener.handle_info({:broadcast, invalid_utf8}, state)

      assert result == invalid_utf8

      Application.put_env(:elixircd, :settings, original_settings)
    end

    test "preserves binary data in binary frames" do
      state = ws_state(:ws, "binary.ircv3.net")
      binary_data = "MESSAGE" <> <<0xFF, 0xFE>>

      assert {:push, {:binary, ^binary_data}, ^state} = WsListener.handle_info({:broadcast, binary_data}, state)
    end

    test "handles disconnect messages" do
      state = ws_state()

      assert {:stop, :normal, {1000, "Client quit"}, %{quit_reason: "Client quit"}} =
               WsListener.handle_info({:disconnect, "Client quit"}, state)
    end

    test "ignores EXIT messages" do
      state = ws_state()

      assert {:ok, ^state} = WsListener.handle_info({:EXIT, self(), :normal}, state)
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

  @spec ws_state(:ws | :wss, nil | String.t()) :: map()
  defp ws_state(transport \\ :ws, subprotocol \\ nil) do
    %{
      conn: %Plug.Conn{remote_ip: {127, 0, 0, 1}, port: 8080},
      transport: transport,
      subprotocol: subprotocol
    }
  end
end
