defmodule ElixIRCd.CLI.Remote do
  @moduledoc "Connects one-command release CLIs to the running local node."

  @doc "Starts a temporary distributed node using the release's node settings."
  @spec connect(String.t()) :: {:ok, node()} | {:error, String.t()}
  def connect(command) do
    with {:ok, server_node, cli_node, name_domain} <- release_nodes(command),
         {:ok, _pid} <- Node.start(cli_node, name_domain: name_domain),
         true <- Node.connect(server_node) do
      {:ok, server_node}
    else
      _ ->
        {:error, "Cannot connect to the running ElixIRCd node; check server availability and local node distribution"}
    end
  end

  @doc "Runs a bounded RPC against the connected server node."
  @spec call(node(), module(), atom(), [term()]) :: term()
  def call(server_node, module, function, args), do: :rpc.call(server_node, module, function, args, 30_000)

  @spec release_nodes(String.t()) :: {:ok, node(), node(), :longnames | :shortnames} | :error
  # The release script exports its node name and distribution mode for this VM.
  # Distributed Erlang requires node names as atoms, including the generated CLI name.
  # sobelow_skip ["DOS.StringToAtom"]
  defp release_nodes(command) do
    distribution = System.get_env("RELEASE_DISTRIBUTION")

    with true <- distribution in ["name", "sname"],
         {:ok, server, host} <- node_parts(System.get_env("RELEASE_NODE")) do
      name_domain = if distribution == "name", do: :longnames, else: :shortnames
      suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      cli = "elixircd-#{command}-cli-#{suffix}"
      cli = if name_domain == :longnames, do: "#{cli}@#{host}", else: cli
      {:ok, String.to_atom("#{server}@#{host}"), String.to_atom(cli), name_domain}
    else
      _ -> :error
    end
  end

  @spec node_parts(String.t() | nil) :: {:ok, String.t(), String.t()} | :error
  defp node_parts(name) do
    case String.split(name || "", "@") do
      [server, host] when server != "" and host != "" ->
        {:ok, server, host}

      [server] when server != "" ->
        {:ok, host} = :inet.gethostname()
        {:ok, server, List.to_string(host)}

      _ ->
        :error
    end
  end
end
