defmodule ElixIRCd.Operators.ManagementTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Operators
  alias ElixIRCd.Tables.Operator

  setup do
    original = Application.fetch_env!(:elixircd, :operators)
    Application.put_env(:elixircd, :operators, [])
    on_exit(fn -> Application.put_env(:elixircd, :operators, original) end)
    :ok
  end

  test "manages database operators and rejects changes to file operators" do
    old_hash = Argon2.hash_pwd_salt("a-long-password")
    new_hash = Argon2.hash_pwd_salt("another-long-password")
    Application.put_env(:elixircd, :operators, [{"file", old_hash}])

    assert :ok = Operators.Management.add("database", old_hash)
    assert {:error, :configured} = Operators.Management.add("file", old_hash)
    assert {:error, :exists} = Operators.Management.add("database", old_hash)
    assert {:error, :configured} = Operators.Management.rotate("file", new_hash)
    assert {:error, :configured} = Operators.Management.disable("file")
    assert {:error, :configured} = Operators.Management.enable("file")
    assert {:error, :configured} = Operators.Management.remove("file")

    assert :ok = Operators.Management.rotate("database", new_hash)

    assert %Operator{password_hash: ^new_hash, enabled: true} =
             Memento.transaction!(fn -> Memento.Query.read(Operator, "database") end)

    assert :ok = Operators.Management.disable("database")
    assert %Operator{enabled: false} = Memento.transaction!(fn -> Memento.Query.read(Operator, "database") end)

    assert :ok = Operators.Management.enable("database")
    assert %Operator{enabled: true} = Memento.transaction!(fn -> Memento.Query.read(Operator, "database") end)

    assert :ok = Operators.Management.remove("database")
    assert nil == Memento.transaction!(fn -> Memento.Query.read(Operator, "database") end)
    assert {:error, :not_found} = Operators.Management.remove("database")
  end

  test "rejects invalid names and hashes without storing records" do
    assert {:error, :invalid_name} = Operators.Management.add("bad name", Argon2.hash_pwd_salt("a-long-password"))
    assert {:error, :invalid_hash} = Operators.Management.add("valid", "plaintext")
    assert [] = Memento.transaction!(fn -> Memento.Query.all(Operator) end)
  end
end
