defmodule ElixIRCd.Repository.Metrics do
  @moduledoc """
  Module for the metrics repository.
  """

  alias ElixIRCd.Tables.Metric

  @metric_keys [:highest_connections, :total_connections]

  @doc """
  Get a metric by the metric key.
  """
  @spec get(Metric.key()) :: integer()
  def get(metric_key) when metric_key in @metric_keys do
    case :mnesia.dirty_read(Metric, metric_key) do
      [] -> 0
      [{_, _, amount} | _] -> amount
    end
  end

  @doc """
  Update a metric value by the metric key and amount.
  """
  @spec update_counter(Metric.key(), integer()) :: non_neg_integer()
  def update_counter(metric_key, amount) when metric_key in @metric_keys do
    :mnesia.dirty_update_counter(Metric, metric_key, amount)
  end
end
