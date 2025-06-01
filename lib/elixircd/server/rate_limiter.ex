defmodule ElixIRCd.Server.RateLimiter do
  @moduledoc """
  Handles rate limiting.
  """

  use Supervisor

  alias ElixIRCd.Repositories.Users

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

  @type burst_result() :: :ok | {:error, :throttled, non_neg_integer()} | {:error, :throttled_exceeded}

  @doc false
  @spec start_link(term()) :: {:ok, pid()} | {:error, term()}
  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

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
  Checks if a connection from the given IP address is not exceeding rate limits or max connections.
  Returns `:ok` if the connection is allowed, `{:error, :throttled, retry_after_ms}` if the connection
  should be throttled, `{:error, :throttled_exceeded}` if the connection has exceeded its rate limit,
  or `{:error, :max_connections_exceeded}` if the connection has exceeded the maximum number of connections.
  """
  @spec check_connection(:inet.ip_address()) :: burst_result() | {:error, :max_connections_exceeded}
  def check_connection(ip) do
    config = Application.get_env(:elixircd, :rate_limiter)[:connection]

    if ip_exception?(ip, config) do
      :ok
    else
      case check_connection_max_per_ip(ip, config) do
        :ok -> check_connection_rate_limits(ip, config)
        error -> error
      end
    end
  end

  @spec ip_exception?(:inet.ip_address(), keyword()) :: boolean()
  defp ip_exception?(ip, config) do
    exceptions = Keyword.get(config, :exceptions, [])

    # Future: Use a configuration builder that parses the IP and CIDR,
    # so that it does not need to be parsed every call here
    exception_ips =
      Keyword.get(exceptions, :ips, [])
      |> Enum.map(fn ip -> ip |> String.to_charlist() |> :inet.parse_address() |> elem(1) end)

    exception_cidrs =
      Keyword.get(exceptions, :cidrs, [])
      |> Enum.map(fn cidr -> cidr |> CIDR.parse() end)

    cond do
      ip in exception_ips -> true
      Enum.any?(exception_cidrs, fn cidr -> CIDR.match!(cidr, ip) end) -> true
      true -> false
    end
  end

  @spec check_connection_max_per_ip(:inet.ip_address(), keyword()) :: :ok | {:error, :max_connections_exceeded}
  defp check_connection_max_per_ip(ip, config) do
    max_connections_per_ip = Keyword.get(config, :max_connections_per_ip)
    current_connections = Users.count_by_ip_address(ip)

    if current_connections < max_connections_per_ip do
      :ok
    else
      {:error, :max_connections_exceeded}
    end
  end

  @spec check_connection_rate_limits(:inet.ip_address(), keyword()) :: burst_result()
  defp check_connection_rate_limits(ip, config) do
    throttle = Keyword.get(config, :throttle)
    ip_string = :inet.ntoa(ip) |> to_string()

    block_ms = throttle[:block_ms]
    block_key = "block:#{ip_string}"

    case Violation.get(block_key, block_ms) do
      count when is_integer(count) and count >= 1 -> {:error, :throttled_exceeded}
      _count -> check_connection_rate(ip_string, throttle)
    end
  end

  @spec check_connection_rate(String.t(), keyword()) :: burst_result()
  defp check_connection_rate(ip_string, throttle) do
    rate_key = "rate:#{ip_string}"

    case Connection.hit(rate_key, ms(throttle[:refill_rate]), throttle[:capacity], throttle[:cost]) do
      {:allow, _count} -> :ok
      {:deny, retry_ms} -> handle_connection_violation(ip_string, throttle, retry_ms)
    end
  end

  @spec handle_connection_violation(String.t(), keyword(), non_neg_integer()) ::
          {:error, :throttled_exceeded} | {:error, :throttled, non_neg_integer()}
  defp handle_connection_violation(ip_string, throttle, retry_ms) do
    window_ms = throttle[:window_ms]
    block_threshold = throttle[:block_threshold]
    violation_key = "violation:#{ip_string}"

    {:allow, count} = Violation.hit(violation_key, window_ms, block_threshold, 1)

    if count >= block_threshold do
      block_ms = throttle[:block_ms]
      block_key = "block:#{ip_string}"

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
  @spec check_message(pid(), String.t()) :: burst_result()
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
