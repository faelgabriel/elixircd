defmodule ElixIRCd.Tables.Job do
  @moduledoc """
  Mnesia table structure for job queue persistence.
  """

  use Memento.Table,
    attributes: [
      :id,
      :type,
      :payload,
      :status,
      :scheduled_at,
      :max_attempts,
      :current_attempt,
      :retry_delay_ms,
      :repeat_interval_ms,
      :last_error,
      :created_at,
      :updated_at
    ],
    index: [:status, :scheduled_at, :type],
    type: :set

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          payload: map(),
          status: :queued | :processing | :done | :failed,
          scheduled_at: DateTime.t(),
          max_attempts: pos_integer(),
          current_attempt: non_neg_integer(),
          retry_delay_ms: pos_integer(),
          repeat_interval_ms: pos_integer() | nil,
          last_error: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Create a new job.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = generate_id()

    %__MODULE__{
      id: id,
      type: Map.fetch!(attrs, :type),
      payload: Map.get(attrs, :payload, %{}),
      status: :queued,
      scheduled_at: Map.get(attrs, :scheduled_at, now),
      max_attempts: Map.get(attrs, :max_attempts, 3),
      current_attempt: 0,
      retry_delay_ms: Map.get(attrs, :retry_delay_ms, 5000),
      repeat_interval_ms: Map.get(attrs, :repeat_interval_ms),
      last_error: nil,
      created_at: now,
      updated_at: now
    }
  end

  @doc """
  Update a job.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = job, attrs) when is_map(attrs) do
    attrs
    |> Map.put(:updated_at, DateTime.utc_now())
    |> Enum.reduce(job, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
