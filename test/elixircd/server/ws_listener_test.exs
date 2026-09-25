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

    test "queues closure after replies and ignores further input when Connection returns quit" do
      state = ws_state()

      expect(Connection, :handle_receive, fn _pid, _data ->
        {:quit, "Quit: Goodbye"}
      end)

      assert {:ok, %{quit_reason: "Quit: Goodbye"} = closing_state} =
               WsListener.handle_in({"QUIT :Goodbye", [opcode: :text]}, state)

      assert_receive {:disconnect, "Quit: Goodbye"}
      assert {:ok, ^closing_state} = WsListener.handle_in({"PING :late", [opcode: :text]}, closing_state)
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

    test "passes through invalid UTF-8 input for UTF8ONLY rejection" do
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
    test "handles a tag-only text payload without applying the tag budget as message data" do
      state = ws_state(:ws, "text.ircv3.net")

      assert {:push, {:text, "@label=value"}, ^state} =
               WsListener.handle_info({:broadcast, "@label=value\r\n"}, state)
    end

    for subprotocol <- [nil, "text.ircv3.net"] do
      test "bounds the final UTF-8 frame after sanitization for #{inspect(subprotocol)}" do
        state = ws_state(:ws, unquote(subprotocol))
        prefix = ":sender!~ident@host PRIVMSG recipient :"
        message = prefix <> :binary.copy(<<255>>, 450) <> "\r\n"
        assert byte_size(message) <= 512
        assert {:push, {:text, frame}, ^state} = WsListener.handle_info({:broadcast, message}, state)
        expected = prefix <> String.duplicate("�", div(510 - byte_size(prefix), 3))
        assert frame == expected
        assert String.valid?(frame)
        assert byte_size(frame) <= 510
      end
    end

    test "budgets the serialized user prefix separately from tags and preserves codepoints" do
      state = ws_state(:ws, "text.ircv3.net")
      tags = "@+example/tag=" <> String.duplicate("a", 600)
      prefix = ":sender!~ident@host PRIVMSG recipient :"
      body = prefix <> String.duplicate("😊", 130)

      assert {:push, {:text, frame}, ^state} =
               WsListener.handle_info({:broadcast, tags <> " " <> body <> "\r\n"}, state)

      assert [^tags, data] = String.split(frame, " ", parts: 2)
      assert data == prefix <> String.duplicate("😊", div(510 - byte_size(prefix), 4))
      assert String.valid?(data)
      assert byte_size(data) <= 510
    end

    test "preserves a full binary IRC payload without UTF-8 expansion" do
      state = ws_state(:ws, "binary.ircv3.net")
      prefix = ":sender!~ident@host PRIVMSG recipient :"
      body = prefix <> :binary.copy(<<255>>, 510 - byte_size(prefix))
      assert {:push, {:binary, ^body}, ^state} = WsListener.handle_info({:broadcast, body <> "\r\n"}, state)
    end

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

    test "sanitizes invalid UTF-8 in text frames when utf8_only is enabled" do
      original_settings = Application.get_env(:elixircd, :settings)
      Application.put_env(:elixircd, :settings, Keyword.merge(original_settings, utf8_only: true))

      state = ws_state(:ws, "text.ircv3.net")
      invalid_utf8 = "MESSAGE" <> <<0xFF, 0xFE>>

      {:push, {:text, result}, ^state} = WsListener.handle_info({:broadcast, invalid_utf8}, state)

      assert result == "MESSAGE��"

      Application.put_env(:elixircd, :settings, original_settings)
    end

    for {protocol, opcode} <- [{"text.ircv3.net", :text}, {"binary.ircv3.net", :binary}, {nil, :text}] do
      test "omits IRC line terminators in #{inspect(protocol)} frames" do
        state = ws_state(:ws, unquote(protocol))

        assert {:push, {unquote(opcode), "NOTICE AUTH :hello"}, ^state} =
                 WsListener.handle_info({:broadcast, "NOTICE AUTH :hello\r\n"}, state)
      end
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
