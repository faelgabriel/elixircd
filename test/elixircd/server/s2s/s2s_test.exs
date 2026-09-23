defmodule ElixIRCd.Server.S2STest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Config.Loader
  alias ElixIRCd.Server.S2S

  test "uses the configured independent connection budget for the native listener" do
    config =
      Loader.read!("config/elixircd.exs")
      |> put_in([:s2s, :enabled], true)
      |> put_in([:s2s, :budgets, :max_connections_per_acceptor], 7)

    assert {:ok, {_supervisor_options, children}} = S2S.init(config: config)
    listener = Enum.find(children, &match?(%{start: {ThousandIsland, :start_link, [_]}}, &1))
    assert %{start: {ThousandIsland, :start_link, [options]}} = listener
    assert options[:num_acceptors] == 4
    assert options[:num_connections] == 7
  end
end
