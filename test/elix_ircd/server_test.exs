defmodule ElixIRCd.ServerTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  doctest ElixIRCd.Server

  alias Ecto.Changeset
  alias ElixIRCd.Client
  alias ElixIRCd.Command
  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Message

  import Mimic

  describe "init/1 by client connection" do
    setup :set_mimic_global

    test "handles successful tcp connection initialization" do
      socket = Client.connect(:ssl)
      assert {:error, :timeout} == Client.recv(socket)
    end

    test "handles successful ssl connection initialization" do
      socket = Client.connect(:ssl)
      assert {:error, :timeout} == Client.recv(socket)
    end

    @tag :capture_log
    test "handles error on tcp connection initialization" do
      Contexts.User
      |> expect(:create, fn _ -> {:error, %Changeset{}} end)

      socket = Client.connect(:tcp)
      assert {:error, :closed} == Client.recv(socket)
    end

    @tag :capture_log
    test "handles error on ssl connection initialization" do
      Contexts.User
      |> expect(:create, fn _ -> {:error, %Changeset{}} end)

      socket = Client.connect(:ssl)
      assert {:error, :closed} == Client.recv(socket)
    end
  end

  describe "connection_loop/2 by client connection" do
    setup :set_mimic_global

    test "handles valid tcp connection packet" do
      Command
      |> expect(:handle, fn _, message ->
        assert %Message{command: "COMMAND", params: ["test"]} == message
        :ok
      end)

      socket = Client.connect(:tcp)
      Client.send(socket, "COMMAND test\r\n")
      Client.recv(socket)
    end

    test "handles valid ssl connection packet" do
      Command
      |> expect(:handle, fn _, message ->
        assert %Message{command: "TEST", params: []} == message
        :ok
      end)

      socket = Client.connect(:ssl)
      Client.send(socket, "TEST\r\n")
      Client.recv(socket)
    end

    test "handles invalid tcp connection packet" do
      reject(&Command.handle/2)

      socket = Client.connect(:tcp)
      Client.send(socket, "\r\n")
      Client.recv(socket)
    end

    test "handles invalid ssl connection packet" do
      reject(&Command.handle/2)

      socket = Client.connect(:ssl)
      Client.send(socket, "\r\n")
      Client.recv(socket)
    end

    test "handles tcp connection closed" do
      socket = Client.connect(:tcp)
      assert :ok == Client.close(socket)
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles ssl connection closed" do
      socket = Client.connect(:ssl)
      assert :ok == Client.close(socket)
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles tcp connection error" do
      assert true
    end

    test "handles ssl connection error" do
      assert true
    end

    test "handles connection timeout" do
      assert true
    end

    test "handles user quit and its cleans up" do
      assert true
    end

    test "handles user quit and logs error when user not found on deletion" do
      assert true
    end
  end

  describe "send_message/2 by client connection" do
    setup :set_mimic_global

    test "sends a message to a single user" do
      assert true
    end

    test "sends a message to multiple users" do
      assert true
    end
  end

  describe "send_messages/2 by client connection" do
    test "sends messages to a single user" do
      assert true
    end

    test "sends messages to multiple users" do
      assert true
    end
  end
end
