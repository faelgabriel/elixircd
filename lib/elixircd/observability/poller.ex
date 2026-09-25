defmodule ElixIRCd.Observability.Poller do
  @moduledoc "Samples inexpensive operational gauges outside scrape requests."

  use GenServer

  require Logger

  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Jobs
  alias ElixIRCd.Utils.Mnesia

  @interval 30_000
  @job_interval 60_000

  @doc "Starts the operational sampler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(state) do
    Process.send_after(self(), :sample, 2_000)
    Process.send_after(self(), :jobs, 2_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    safely(&sample/0)
    Process.send_after(self(), :sample, @interval)
    {:noreply, state}
  end

  def handle_info(:jobs, state) do
    safely(&sample_jobs/0)
    Process.send_after(self(), :jobs, @job_interval)
    {:noreply, state}
  end

  defp safely(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("observability sample failed", event: "observability.sample_failed", error_type: error.__struct__)
  catch
    :exit, _ -> Logger.warning("observability sample failed", event: "observability.sample_failed", error_type: :exit)
  end

  defp sample do
    ready = if Observability.readiness() == :ok, do: 1, else: 0
    disk = disk_space()

    Observability.emit([:sample], %{
      ready: ready,
      timestamp: System.system_time(:second),
      memory_bytes: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count),
      run_queue: :erlang.statistics(:run_queue),
      ets_bytes: :erlang.memory(:ets),
      atoms: :erlang.system_info(:atom_count),
      ports: :erlang.system_info(:port_count),
      disk_available_bytes: disk.available,
      disk_capacity_bytes: disk.capacity
    })

    if ready == 1 do
      Enum.each(Mnesia.all_tables(), fn table ->
        Observability.emit([:table, :sample], %{rows: :mnesia.table_info(table, :size)}, %{table: table})
      end)
    end
  end

  defp sample_jobs do
    now = DateTime.utc_now()

    {queued, processing, failed} =
      Memento.transaction!(fn ->
        {Jobs.get_by_status(:queued), Jobs.get_by_status(:processing), Jobs.get_by_status(:failed)}
      end)

    oldest_age =
      Enum.reduce(queued, 0, fn job, oldest -> max(oldest, DateTime.diff(now, job.scheduled_at)) end)

    Observability.emit([:jobs, :sample], %{
      queued: length(queued),
      processing: length(processing),
      failed: length(failed),
      oldest_age: oldest_age
    })
  end

  defp disk_space do
    case System.cmd("df", ["-Pk", Path.expand("data")], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.split()
        |> parse_disk_fields()

      {_output, _status} ->
        %{capacity: 0, available: 0}
    end
  end

  defp parse_disk_fields([_filesystem, capacity, _used, available, _percent | _rest]) do
    with {capacity_kib, ""} when capacity_kib > 0 <- Integer.parse(capacity),
         {available_kib, ""} <- Integer.parse(available) do
      %{capacity: capacity_kib * 1024, available: available_kib * 1024}
    else
      _ -> %{capacity: 0, available: 0}
    end
  end

  defp parse_disk_fields(_fields), do: %{capacity: 0, available: 0}
end
