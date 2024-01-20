defmodule ElixIRCd.ServerTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  doctest ElixIRCd.Server

  alias ElixIRCd.Client
  alias ElixIRCd.Command
  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message

  import ElixIRCd.Factory
  import ExUnit.CaptureLog
  import Mimic

  describe "init/1 by client connection" do
    setup :set_mimic_global
    setup :verify_on_exit!

    test "handles successful tcp connect" do
      :ranch_tcp
      |> expect(:setopts, 1, fn _socket, opts ->
        assert opts == [{:packet, :line}, {:reuseaddr, true}]
        :ok
      end)

      :ranch_tcp
      |> expect(:setopts, 1, fn _socket, opts ->
        assert opts == [{:active, :once}]
        :ok
      end)

      assert {:ok, socket} = Client.connect(:tcp)
      assert {:error, :timeout} == Client.recv(socket), "The connection got closed"
      assert [%Schemas.User{}] = Repo.all(Schemas.User)
    end

    test "handles successful ssl connect" do
      :ranch_ssl
      |> expect(:setopts, 1, fn _socket, opts ->
        assert opts == [{:packet, :line}, {:reuseaddr, true}]
        :ok
      end)

      :ranch_ssl
      |> expect(:setopts, 1, fn _socket, opts ->
        assert opts == [{:active, :once}]
        :ok
      end)

      assert {:ok, socket} = Client.connect(:ssl)
      assert {:error, :timeout} == Client.recv(socket), "The connection got closed"
      assert [%Schemas.User{}] = Repo.all(Schemas.User)
    end

    test "handles ranch handshake error on tcp connect" do
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
      assert [] = Repo.all(Schemas.User)
    end

    test "handles ranch handshake error on ssl connect" do
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
      assert [] = Repo.all(Schemas.User)
    end

    test "handles user create error on tcp connect" do
      Contexts.User
      |> expect(:create, 1, fn _params -> {:error, %Ecto.Changeset{}} end)

      log =
        capture_log(fn ->
          assert {:ok, socket} = Client.connect(:tcp)
          assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
        end)

      assert log =~ "[error] Error initializing connection: {:error, \"Error creating user:"
      assert [] = Repo.all(Schemas.User)
    end

    test "handles user create error on ssl connect" do
      Contexts.User
      |> expect(:create, 1, fn _params -> {:error, %Ecto.Changeset{}} end)

      log =
        capture_log(fn ->
          # ssl socket is returned if the error was not in the handshake, so we check for recv response
          assert {:ok, socket} = Client.connect(:tcp)
          assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
        end)

      assert log =~ "[error] Error initializing connection: {:error, \"Error creating user:"
      assert [] = Repo.all(Schemas.User)
    end

    test "handles valid tcp packet" do
      Command
      |> expect(:handle, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"
      assert [%Schemas.User{}] = Repo.all(Schemas.User)
    end

    test "handles valid ssl packet" do
      Command
      |> expect(:handle, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"
      assert [%Schemas.User{}] = Repo.all(Schemas.User)
    end

    test "handles invalid tcp packet" do
      Command
      |> reject(:handle, 2)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "\r\n")
      Client.send(socket, " \r\n")
      Client.send(socket, " \r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"
      assert [%Schemas.User{}] = Repo.all(Schemas.User)
    end

    test "handles invalid ssl packet" do
      Command
      |> reject(:handle, 2)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "\r\n")
      Client.send(socket, " \r\n")
      Client.send(socket, " \r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"
      assert [%Schemas.User{}] = Repo.all(Schemas.User)
    end

    test "handles successful tcp disconnect by tcp close" do
      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)
      [%Schemas.User{} = user] = Repo.all(Schemas.User)

      insert(:user_channel, user: user, channel: insert(:channel))
      [%Schemas.UserChannel{}] = Repo.all(Schemas.UserChannel)

      send(user.pid, {:tcp_closed, user.socket})
      :timer.sleep(100)

      assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
      assert [] = Repo.all(Schemas.UserChannel)
      assert [] = Repo.all(Schemas.User)
    end

    test "handles successful ssl disconnect by ssl close" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%Schemas.User{} = user] = Repo.all(Schemas.User)

      insert(:user_channel, user: user, channel: insert(:channel))
      [%Schemas.UserChannel{}] = Repo.all(Schemas.UserChannel)

      send(user.pid, {:ssl_closed, user.socket})
      :timer.sleep(100)

      assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
      assert [] = Repo.all(Schemas.UserChannel)
      assert [] = Repo.all(Schemas.User)
    end

    test "handles successful tcp disconnect by tcp error" do
      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)
      [%Schemas.User{} = user] = Repo.all(Schemas.User)

      insert(:user_channel, user: user, channel: insert(:channel))
      [%Schemas.UserChannel{}] = Repo.all(Schemas.UserChannel)

      log =
        capture_log(fn ->
          send(user.pid, {:tcp_error, user.socket, :any_error})
          :timer.sleep(100)
        end)

      assert log =~ "TCP connection error: :any_error"
      assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
      assert [] = Repo.all(Schemas.UserChannel)
      assert [] = Repo.all(Schemas.User)
    end

    test "handles successful ssl disconnect by ssl error" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%Schemas.User{} = user] = Repo.all(Schemas.User)

      insert(:user_channel, user: user, channel: insert(:channel))
      [%Schemas.UserChannel{}] = Repo.all(Schemas.UserChannel)

      log =
        capture_log(fn ->
          send(user.pid, {:ssl_error, user.socket, :any_error})
          :timer.sleep(100)
        end)

      assert log =~ "SSL connection error: :any_error"
      assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
      assert [] = Repo.all(Schemas.UserChannel)
      assert [] = Repo.all(Schemas.User)
    end

    test "handles successful tcp disconnect by unexpected error rescued" do
      Command
      |> expect(:handle, 1, fn _user, _message ->
        raise "An error has occurred"
      end)

      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)
      [%Schemas.User{} = user] = Repo.all(Schemas.User)

      insert(:user_channel, user: user, channel: insert(:channel))
      [%Schemas.UserChannel{}] = Repo.all(Schemas.UserChannel)

      log =
        capture_log(fn ->
          Client.send(socket, "COMMAND test\r\n")
          :timer.sleep(100)
        end)

      assert log =~ "Error handling connection: %RuntimeError{message: \"An error has occurred\"}"
      assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
      assert [] = Repo.all(Schemas.UserChannel)
      assert [] = Repo.all(Schemas.User)
    end

    test "handles successful ssl disconnect by unexpected error rescued" do
      Command
      |> expect(:handle, 1, fn _user, _message ->
        raise "An error has occurred"
      end)

      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%Schemas.User{} = user] = Repo.all(Schemas.User)

      insert(:user_channel, user: user, channel: insert(:channel))
      [%Schemas.UserChannel{}] = Repo.all(Schemas.UserChannel)

      log =
        capture_log(fn ->
          Client.send(socket, "COMMAND test\r\n")
          :timer.sleep(100)
        end)

      assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
      assert log =~ "Error handling connection: %RuntimeError{message: \"An error has occurred\"}"
      assert [] = Repo.all(Schemas.UserChannel)
      assert [] = Repo.all(Schemas.User)
    end

    test "handles successful disconnect by connection timeout" do
      original_timeout = Application.get_env(:elixircd, :client_timeout)
      Application.put_env(:elixircd, :client_timeout, 110)

      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%Schemas.User{} = user] = Repo.all(Schemas.User)

      insert(:user_channel, user: user, channel: insert(:channel))
      [%Schemas.UserChannel{}] = Repo.all(Schemas.UserChannel)

      :timer.sleep(200)

      assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
      assert [] = Repo.all(Schemas.UserChannel)
      assert [] = Repo.all(Schemas.User)

      Application.put_env(:elixircd, :client_timeout, original_timeout)
    end

    test "handles successful disconnect by user quit" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%Schemas.User{} = user] = Repo.all(Schemas.User)

      insert(:user_channel, user: user, channel: insert(:channel))
      [%Schemas.UserChannel{}] = Repo.all(Schemas.UserChannel)

      send(user.pid, {:user_quit, user.socket, "Quit message"})
      :timer.sleep(100)

      assert {:error, :closed} == Client.recv(socket), "The connection did not get closed"
      assert [] = Repo.all(Schemas.UserChannel)
      assert [] = Repo.all(Schemas.User)
    end
  end
end
