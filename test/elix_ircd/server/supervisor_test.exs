defmodule ElixIRCd.Server.SupervisorTest do
  @moduledoc false

  use ExUnit.Case
  doctest ElixIRCd.Server.Supervisor

  alias ElixIRCd.Server

  describe "init/1" do
    test "starts the server supervisor with ipv6 disabled" do
      assert {:ok, _} = Server.Supervisor.init([{:tcp_ports, [9999]}, {:enable_ipv6, false}])
    end
  end
end
