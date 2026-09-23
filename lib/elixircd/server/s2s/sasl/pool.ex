defmodule ElixIRCd.Server.S2S.SASL.Pool do
  @moduledoc """
  Fixed-size transient worker pool for native SASL verification.

  The pool has no waiting queue. Once every worker is occupied, a new attempt
  receives `:busy` and the request layer can return `BUSY` without retaining
  credential data or growing a mailbox-backed job queue.
  """

  use GenServer

  @type job_ref :: reference()

  @doc "Starts a fixed-size SASL verification pool."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Submits one transient verification job to an idle worker."
  @spec submit(GenServer.server(), pid(), (-> term())) :: {:ok, job_ref()} | :busy
  def submit(server, owner, fun) when is_pid(owner) and is_function(fun, 0) do
    GenServer.call(server, {:submit, owner, fun})
  end

  @doc "Stops the pool and discards all transient worker state."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  @doc "Cancels one running verification job and replaces its worker."
  @spec cancel(GenServer.server(), job_ref()) :: :ok
  def cancel(server, job_ref) when is_reference(job_ref) do
    GenServer.call(server, {:cancel, job_ref})
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(options) do
    worker_count = Keyword.get(options, :max_workers, 4)

    if is_integer(worker_count) and worker_count > 0 do
      {:ok, %{workers: start_workers(worker_count), stopping?: false}}
    else
      {:stop, :invalid_worker_count}
    end
  end

  @impl true
  def handle_call({:submit, owner, fun}, _from, state) do
    case Enum.find(state.workers, fn {_pid, worker} -> worker.job == nil end) do
      nil ->
        {:reply, :busy, state}

      {pid, _worker} ->
        job_ref = make_ref()
        send(pid, {:run, job_ref, owner, fun})
        workers = Map.update!(state.workers, pid, &Map.put(&1, :job, job_ref))
        {:reply, {:ok, job_ref}, %{state | workers: workers}}
    end
  end

  @impl true
  def handle_call({:cancel, job_ref}, _from, state) do
    case Enum.find(state.workers, fn {_pid, worker} -> worker.job == job_ref end) do
      {pid, _worker} -> Process.exit(pid, :kill)
      nil -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:worker_done, pid, job_ref}, state) do
    case state.workers[pid] do
      %{job: ^job_ref} = worker ->
        {:noreply, %{state | workers: Map.put(state.workers, pid, %{worker | job: nil})}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case state.workers[pid] do
      %{monitor: ^monitor} ->
        if state.stopping? do
          {:noreply, %{state | workers: Map.delete(state.workers, pid)}}
        else
          replacement = start_worker(self())
          workers = state.workers |> Map.delete(pid) |> Map.put(elem(replacement, 0), elem(replacement, 1))
          {:noreply, %{state | workers: workers}}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.workers, fn {pid, _worker} -> send(pid, :stop) end)
    :ok
  end

  defp start_workers(count), do: Map.new(1..count, fn _ -> start_worker(self()) end)

  defp start_worker(pool) do
    pid = spawn(fn -> worker_loop(pool) end)
    monitor = Process.monitor(pid)
    {pid, %{monitor: monitor, job: nil}}
  end

  defp worker_loop(pool) do
    receive do
      {:run, job_ref, owner, fun} ->
        result = run(fun)
        send(owner, {:s2s_sasl_result, job_ref, result})
        send(pool, {:worker_done, self(), job_ref})
        worker_loop(pool)

      :stop ->
        :ok
    end
  end

  defp run(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, {:worker_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:worker_exit, kind, reason}}
  end
end
