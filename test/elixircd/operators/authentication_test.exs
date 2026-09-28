defmodule ElixIRCd.Operators.AuthenticationTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  alias ElixIRCd.Operators
  alias ElixIRCd.Utils.Mnesia

  setup do
    original = Application.fetch_env!(:elixircd, :operators)
    Application.put_env(:elixircd, :operators, [])
    on_exit(fn -> Application.put_env(:elixircd, :operators, original) end)
    :ok
  end

  test "authenticates file and database operators and rejects disabled credentials" do
    file_hash = Argon2.hash_pwd_salt("file-long-password")
    database_hash = Argon2.hash_pwd_salt("database-long-password")
    Application.put_env(:elixircd, :operators, [{"file", file_hash}])
    assert :ok = Operators.Management.add("database", database_hash)

    assert {:ok, %{source: :config, name: "file"}} =
             Operators.Authentication.authenticate("file", "file-long-password")

    assert {:ok, %{source: :database, name: "database"}} =
             Operators.Authentication.authenticate("database", "database-long-password")

    assert :error = Operators.Authentication.authenticate("database", "wrong-password")
    assert :ok = Operators.Management.disable("database")
    assert :error = Operators.Authentication.authenticate("database", "database-long-password")
  end

  test "fails closed when the operator table is unavailable" do
    assert :ok = Supervisor.terminate_child(ElixIRCd, ElixIRCd.JobQueue)

    try do
      Memento.stop()
      assert :error = Operators.Authentication.authenticate("managed", "a-long-password")
    after
      Memento.start()
      Memento.wait(Mnesia.all_tables())
      Supervisor.restart_child(ElixIRCd, ElixIRCd.JobQueue)
    end
  end

  test "fails closed if its database transaction exits" do
    stub(Memento, :transaction!, fn _fun -> exit(:nodedown) end)
    assert :error = Operators.Authentication.authenticate("managed", "a-long-password")
  end
end
