defmodule ElixIRCd.ServerTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  doctest ElixIRCd.Server

  alias Ecto.Changeset
  alias ElixIRCd.Client
  alias ElixIRCd.Data.Contexts

  import Mimic

  describe "init/1 - client connection" do
    setup :set_mimic_global

    @tag :capture_log
    test "handles internal context error on tcp connecting" do
      Contexts.User
      |> expect(:create, fn _ -> {:error, %Changeset{}} end)

      socket = Client.connect(:tcp)

      assert {:error, :closed} == Client.recv(socket)
    end

    @tag :capture_log
    test "handles internal context error on ssl connecting" do
      Contexts.User
      |> expect(:create, fn _ -> {:error, %Changeset{}} end)

      socket = Client.connect(:ssl)

      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles tcp connection closed" do
      socket = Client.connect(:tcp)

      assert {:error, :timeout} == Client.recv(socket)
      assert :ok == Client.close(socket)
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles ssl connection closed" do
      socket = Client.connect(:ssl)

      assert {:error, :timeout} == Client.recv(socket)
      assert :ok == Client.close(socket)
      assert {:error, :closed} == Client.recv(socket)
    end
  end
end
