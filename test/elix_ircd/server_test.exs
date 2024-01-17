defmodule ElixIRCd.ServerTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  doctest ElixIRCd.Server

  alias ElixIRCd.Client
  alias ElixIRCd.Command
  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Message

  import ExUnit.CaptureLog
  import Mimic

  describe "init/1 by client connection" do
    setup :set_mimic_global
    setup :verify_on_exit!

    test "handles successful tcp connection initialization" do
      :ranch_tcp
      |> expect(:setopts, 2, fn _socket, _opts -> :ok end)

      assert {:ok, socket} = Client.connect(:tcp)
      assert {:error, :timeout} == Client.recv(socket), "The connection got closed"
    end

    test "handles successful ssl connection initialization" do
      :ranch_ssl
      |> expect(:setopts, 2, fn _socket, _opts -> :ok end)

      assert {:ok, socket} = Client.connect(:ssl)
      assert {:error, :timeout} == Client.recv(socket), "The connection got closed"
    end

    test "handles ranch handshake error on tcp connection initialization" do
      :ranch
      |> expect(:handshake, 1, fn _ref -> :error end)

      :ranch_tcp
      |> reject(:setopts, 2)

      log =
        capture_log(fn ->
          assert {:ok, socket} = Client.connect(:tcp)
          assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
        end)

      assert log =~ "[error] Error initializing connection: :error"
    end

    test "handles ranch handshake error on ssl connection initialization" do
      :ranch
      |> expect(:handshake, 1, fn _ref -> :error end)

      :ranch_ssl
      |> reject(:setopts, 2)

      log =
        capture_log(fn ->
          # ssl socket is not returned if the handshake erroed
          assert {:error, :closed} = Client.connect(:ssl)
        end)

      assert log =~ "[error] Error initializing connection: :error"
    end

    test "handles user create error on tcp connection initialization" do
      Contexts.User
      |> expect(:create, 1, fn _params -> {:error, %Ecto.Changeset{}} end)

      log =
        capture_log(fn ->
          assert {:ok, socket} = Client.connect(:tcp)
          assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
        end)

      assert log =~ "[error] Error initializing connection: {:error, \"Error creating user:"
    end

    test "handles user create error on ssl connection initialization" do
      Contexts.User
      |> expect(:create, 1, fn _params -> {:error, %Ecto.Changeset{}} end)

      log =
        capture_log(fn ->
          # ssl socket is returned if the error was not in the handshake, so we check for recv response
          assert {:ok, socket} = Client.connect(:tcp)
          assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
        end)

      assert log =~ "[error] Error initializing connection: {:error, \"Error creating user:"
    end
  end

  describe "handle_connection/2 by client connection" do
    setup :set_mimic_global
    setup :verify_on_exit!

    test "handles valid tcp connection packet (handle_packet/2)" do
      Command
      |> expect(:handle, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"
    end

    test "handles valid ssl connection packet (handle_packet/2)" do
      Command
      |> expect(:handle, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"
    end

    test "handles invalid tcp connection packet (handle_packet/2)" do
      Command
      |> reject(:handle, 2)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "\r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"
    end

    test "handles invalid ssl connection packet (handle_packet/2)" do
      Command
      |> reject(:handle, 2)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "\r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"
    end
  end
end
