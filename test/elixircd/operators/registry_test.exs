defmodule ElixIRCd.Operators.RegistryTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Config.Error
  alias ElixIRCd.Operators

  setup do
    original = Application.fetch_env!(:elixircd, :operators)
    Application.put_env(:elixircd, :operators, [])
    on_exit(fn -> Application.put_env(:elixircd, :operators, original) end)
    :ok
  end

  test "lists operators from both sources with status and without hashes" do
    hash = Argon2.hash_pwd_salt("a-long-password")
    Application.put_env(:elixircd, :operators, [{"file", hash}])
    assert :ok = Operators.Management.add("database", hash)
    assert :ok = Operators.Management.disable("database")

    assert [{"database", :database, false}, {"file", :config, true}] = Operators.Registry.list()
  end

  test "rejects a file operator name already stored in the database" do
    assert :ok = Operators.Management.add("shared", Argon2.hash_pwd_salt("a-long-password"))
    configured = [operators: [{"shared", Argon2.hash_pwd_salt("another-long-password")}]]

    error = assert_raise Error, fn -> Operators.Registry.validate_config!(configured, "config/elixircd.exs") end
    assert Exception.message(error) =~ "also stored in database: shared"
    assert Application.fetch_env!(:elixircd, :operators) == []
  end
end
