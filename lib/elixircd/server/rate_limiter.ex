defmodule ElixIRCd.Server.RateLimiter do
  @moduledoc """
  Handles rate limiting.
  """

  use Supervisor

  defmodule Connection do
    @moduledoc """
    Handles connection-based rate limiting using token bucket algorithm.
    """

    use Hammer, backend: :ets, algorithm: :token_bucket
  end

  defmodule Message do
    @moduledoc """
    Handles message-based rate limiting using token bucket algorithm.
    """

    use Hammer, backend: :ets, algorithm: :token_bucket
  end

  defmodule Violation do
    @moduledoc """
    Tracks rate limit violations.
    """

    use Hammer, backend: :ets
  end

  @doc false
  @spec start_link(term()) :: {:ok, pid()} | {:error, term()}
  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @type check_result() :: :ok | {:error, :throttled, non_neg_integer()} | {:error, :throttled_exceeded}

  @impl true
  def init(_) do
    children = [
      {Connection, [clean_period: :timer.minutes(5), key_older_than: :timer.hours(1)]},
      {Message, [clean_period: :timer.minutes(5), key_older_than: :timer.hours(1)]},
      {Violation, [clean_period: :timer.minutes(5), key_older_than: :timer.hours(1)]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Checks if a connection from the given IP address is within rate limits.
  Returns `:ok` if the connection is allowed, `{:error, :throttled, retry_after_ms}` if the connection
  should be throttled, or `{:error, :throttled_exceeded}` if the connection has exceeded its limits.
  """
  @spec check_connection(:inet.ip_address()) :: check_result()
  def check_connection(ip) do
    ip_string = :inet.ntoa(ip) |> to_string()

    config = Application.get_env(:elixircd, :rate_limiter)[:connection]
    whitelist = Keyword.get(config, :whitelist, [])

    if ip_string in whitelist do
      :ok
    else
      check_connection_rate_limits(ip_string, config)
    end
  end

  @spec check_connection_rate_limits(ip_string :: String.t(), config :: keyword()) :: check_result()
  defp check_connection_rate_limits(ip_string, config) do
    throttle = Keyword.get(config, :throttle)

    block_key = "block:#{ip_string}"
    rate_key = "rate:#{ip_string}"
    violation_key = "violation:#{ip_string}"

    block_threshold = throttle[:block_threshold]
    block_ms = throttle[:block_ms]
    window_ms = throttle[:window_ms]

    check_connection_block(block_key, block_ms, rate_key, throttle, violation_key, window_ms, block_threshold)
  end

  @spec check_connection_block(
          block_key :: String.t(),
          block_ms :: non_neg_integer(),
          rate_key :: String.t(),
          throttle :: keyword(),
          violation_key :: String.t(),
          window_ms :: non_neg_integer(),
          block_threshold :: non_neg_integer()
        ) :: check_result()
  defp check_connection_block(block_key, block_ms, rate_key, throttle, violation_key, window_ms, block_threshold) do
    case Violation.get(block_key, block_ms) do
      count when is_integer(count) and count >= 1 ->
        {:error, :throttled_exceeded}

      _count ->
        check_connection_rate(rate_key, throttle, violation_key, window_ms, block_threshold, block_key, block_ms)
    end
  end

  @spec check_connection_rate(
          rate_key :: String.t(),
          throttle :: keyword(),
          violation_key :: String.t(),
          window_ms :: non_neg_integer(),
          block_threshold :: non_neg_integer(),
          block_key :: String.t(),
          block_ms :: non_neg_integer()
        ) :: check_result()
  defp check_connection_rate(rate_key, throttle, violation_key, window_ms, block_threshold, block_key, block_ms) do
    case Connection.hit(rate_key, ms(throttle[:refill_rate]), throttle[:capacity], throttle[:cost]) do
      {:allow, _count} ->
        :ok

      {:deny, retry_ms} ->
        handle_connection_violation(violation_key, window_ms, block_threshold, block_key, block_ms, retry_ms)
    end
  end

  @spec handle_connection_violation(
          violation_key :: String.t(),
          window_ms :: non_neg_integer(),
          block_threshold :: non_neg_integer(),
          block_key :: String.t(),
          block_ms :: non_neg_integer(),
          retry_ms :: non_neg_integer()
        ) :: {:error, :throttled_exceeded} | {:error, :throttled, non_neg_integer()}
  defp handle_connection_violation(violation_key, window_ms, block_threshold, block_key, block_ms, retry_ms) do
    {:allow, count} = Violation.hit(violation_key, window_ms, block_threshold, 1)

    if count >= block_threshold do
      Violation.hit(block_key, block_ms, 1, 1)
      {:error, :throttled_exceeded}
    else
      {:error, :throttled, retry_ms}
    end
  end

  @doc """
  Checks if a message from a connection is within rate limits.
  Returns `:ok` if the message is allowed, `{:error, :throttled, retry_after_ms}` if the connection
  should be throttled, or `{:error, :throttled_exceeded}` if the connection has exceeded its limits.
  """
  @spec check_message(pid(), String.t()) :: check_result()
  def check_message(pid, data) do
    command = extract_command(data)
    pid_string = inspect(pid)

    config = Application.get_env(:elixircd, :rate_limiter)[:message]
    override = Map.get(config[:command_throttle] || %{}, command, [])
    throttle = Keyword.merge(config[:throttle], override)

    rate_key = "#{pid_string}:#{command || "*"}"
    violation_key = "disconnect:#{rate_key}"

    disconnect_threshold = throttle[:disconnect_threshold]
    window_ms = throttle[:window_ms]

    case Message.hit(rate_key, ms(throttle[:refill_rate]), throttle[:capacity], throttle[:cost]) do
      {:allow, _count} ->
        :ok

      {:deny, retry_ms} ->
        {:allow, count} = Violation.hit(violation_key, window_ms, disconnect_threshold, 1)

        if count >= disconnect_threshold do
          {:error, :throttled_exceeded}
        else
          {:error, :throttled, retry_ms}
        end
    end
  end

  @spec ms(float()) :: pos_integer()
  defp ms(rate), do: trunc(1000 / rate)

  @spec extract_command(String.t()) :: String.t() | nil
  defp extract_command(data) do
    [command | _rest] = String.split(data, " ", parts: 2)

    case command do
      "" -> nil
      _ -> String.upcase(command)
    end
  end
end
