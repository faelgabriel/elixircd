defmodule ElixIRCd.Operators.Remote do
  @moduledoc "Release node RPC boundary for the operator administration command."

  alias ElixIRCd.Operators

  @doc "Calls the running standalone release node."
  @spec call(node(), atom(), list()) :: term()
  def call(server_node, :list, []), do: :rpc.call(server_node, Operators.Registry, :list, [], 30_000)
  def call(server_node, operation, args), do: :rpc.call(server_node, Operators.Management, operation, args, 30_000)
end
