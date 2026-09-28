defmodule ElixIRCd.Operators.RemoteTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ElixIRCd.Operators

  test "reports an unavailable standalone release for reads and writes" do
    assert match?({:badrpc, _}, Operators.Remote.call(:"elixircd-test-unavailable@127.0.0.1", :list, []))
    assert match?({:badrpc, _}, Operators.Remote.call(:"elixircd-test-unavailable@127.0.0.1", :disable, ["managed"]))
  end
end
