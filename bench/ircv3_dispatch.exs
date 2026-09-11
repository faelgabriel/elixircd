# Run with: mix run --no-start bench/ircv3_dispatch.exs --baseline 0eadac6
# Measures command/dispatcher CPU work in one VM, excluding sockets and Mnesia.
# Both versions use the same no-op transport, configuration and dependency set.

defmodule ElixIRCd.Benchmark.Connection do
  def handle_send(_pid, _wire), do: :ok
end

defmodule ElixIRCd.Benchmark.Runner do
  def compile(source, namespace) do
    source
    |> String.replace("ElixIRCd.Server.Connection", "ElixIRCd.Benchmark.Connection")
    |> String.replace("ElixIRCd.Server.Dispatcher", "#{namespace}.Dispatcher")
    |> String.replace("ElixIRCd.Server.ResponseContext", "#{namespace}.ResponseContext")
    |> String.replace("defmodule ElixIRCd.Command do", "defmodule #{namespace}.Command do")
    |> Code.compile_string()
  end

  def measure(fun, iterations) do
    :erlang.garbage_collect()
    {:reductions, before_reductions} = Process.info(self(), :reductions)
    {elapsed, _} = :timer.tc(fn -> repeat(fun, iterations) end)
    {:reductions, after_reductions} = Process.info(self(), :reductions)
    %{us: elapsed / iterations, reductions: (after_reductions - before_reductions) / iterations}
  end

  def repeat(_fun, 0), do: :ok

  def repeat(fun, remaining) do
    fun.()
    repeat(fun, remaining - 1)
  end

  def compare(name, old, current, iterations) do
    repeat(old, 100)
    repeat(current, 100)

    samples =
      for round <- 1..9 do
        if rem(round, 2) == 0 do
          new_sample = measure(current, iterations)
          {measure(old, iterations), new_sample}
        else
          old_sample = measure(old, iterations)
          {old_sample, measure(current, iterations)}
        end
      end

    old_us = median(samples, 0, :us)
    new_us = median(samples, 1, :us)

    %{
      scenario: name,
      baseline_us: old_us,
      current_us: new_us,
      change_percent: 100 * (new_us / old_us - 1),
      baseline_reductions: median(samples, 0, :reductions),
      current_reductions: median(samples, 1, :reductions)
    }
  end

  defp median(samples, index, field) do
    samples |> Enum.map(&elem(&1, index)[field]) |> Enum.sort() |> Enum.at(4)
  end
end

alias ElixIRCd.Benchmark.Runner
alias ElixIRCd.Message

{options, [], []} = OptionParser.parse(System.argv(), strict: [baseline: :string, repository: :string])
baseline = Keyword.get(options, :baseline, "0eadac6")
repository = Keyword.get(options, :repository, ".")

ElixIRCd.Utils.System.load_configurations()

for file <- ["lib/elixircd/server/dispatcher.ex", "lib/elixircd/command.ex"] do
  {source, 0} = System.cmd("git", ["show", "#{baseline}:#{file}"], cd: repository)
  Runner.compile(source, "ElixIRCd.Benchmark.Before")
end

["lib/elixircd/server/response_context.ex", "lib/elixircd/server/dispatcher.ex", "lib/elixircd/command.ex"]
|> Enum.map_join("\n", &File.read!/1)
|> Runner.compile("ElixIRCd.Benchmark.After")

pids = for _index <- 1..100, do: spawn(fn -> receive do: (:stop -> :ok) end)
user = ElixIRCd.Factory.build(:user, pid: self(), nick: "Benchmark", ident: "bench", hostname: "localhost")
message = %Message{command: "NOTICE", params: ["Benchmark"], trailing: "benchmark"}
unknown = %Message{command: "UNKNOWN", params: []}

try do
  results =
    for {label, caps} <- [
          {"no capabilities", []},
          {"legacy tags", ["message-tags", "echo-message"]},
          {"legacy full tags", ["message-tags", "echo-message", "server-time", "msgid", "account-tag"]}
        ],
        {scenario, iterations} <- [{:command, 20_000}, {:single, 20_000}, {:fanout, 300}, {:burst, 100}, {:echo, 300}] do
      message = if label == "legacy full tags", do: %{message | tags: %{"+example.test/tag" => "value"}}, else: message
      recipient = %{user | capabilities: caps}
      targets = Enum.map(pids, &%{recipient | pid: &1})
      burst = List.duplicate(message, 1_000)

      callbacks =
        for namespace <- [ElixIRCd.Benchmark.Before, ElixIRCd.Benchmark.After] do
          dispatcher = Module.concat(namespace, Dispatcher)
          command = Module.concat(namespace, Command)

          case scenario do
            :command -> fn -> command.dispatch(recipient, unknown) end
            :single -> fn -> dispatcher.broadcast(message, :server, recipient) end
            :fanout -> fn -> dispatcher.broadcast(message, :server, targets) end
            :burst -> fn -> dispatcher.broadcast(burst, :server, recipient) end
            :echo -> fn -> dispatcher.broadcast_with_echo(message, recipient, targets) end
          end
        end

      [old, current] = callbacks
      Runner.compare("#{label}: #{scenario}", old, current, iterations)
    end

  IO.puts(
    Jason.encode!(%{baseline: baseline, elixir: System.version(), otp: System.otp_release(), results: results},
      pretty: true
    )
  )
after
  Enum.each(pids, &send(&1, :stop))
end
