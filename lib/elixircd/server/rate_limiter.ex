defmodule ElixIRCd.Server.RateLimiter do
  @moduledoc """
  Handles rate limiting.
  """

  use Supervisor

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  defmodule Connection do
    @moduledoc """
    Handles connection-based rate limiting.
    """

    use Hammer, backend: :ets, algorithm: :token_bucket
  end

  defmodule Message do
    @moduledoc """
    Handles message-based rate limiting.
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
        {:error, :max_connections_exceeded} -> {:error, :max_connections_exceeded}
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
      # Check if IP is in exception list
      ip in exception_ips -> true
      # Check if IP matches any exception CIDR
      Enum.any?(exception_cidrs, fn cidr -> CIDR.match!(cidr, ip) end) -> true
      # No exceptions found
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

    check_connection_rate(ip_string, throttle)
  end

  @spec check_connection_rate(String.t(), keyword()) :: burst_result()
  defp check_connection_rate(ip_string, throttle) do
    rate_key = "rate:#{ip_string}"

    refill_rate = throttle[:refill_rate]
    capacity = throttle[:capacity]
    cost = throttle[:cost]

    case Connection.hit(rate_key, refill_rate, capacity, cost) do
      {:allow, _count} ->
        :ok

      {:deny, _timeout} ->
        retry_ms = calculate_token_wait_time(Connection, rate_key, refill_rate, capacity, cost)
        handle_connection_violation(ip_string, throttle, retry_ms)
    end
  end

  @spec handle_connection_violation(String.t(), keyword(), non_neg_integer()) ::
          {:error, :throttled_exceeded} | {:error, :throttled, non_neg_integer()}
  defp handle_connection_violation(ip_string, throttle, retry_ms) do
    window_ms = throttle[:window_ms]
    block_threshold = throttle[:block_threshold]
    violation_key = "violation:#{ip_string}"

    case Violation.hit(violation_key, window_ms, block_threshold) do
      {:allow, count} when count >= block_threshold -> {:error, :throttled_exceeded}
      {:allow, _count} -> {:error, :throttled, retry_ms}
    end
  end

  @doc """
  Checks if a message from a connection is within rate limits.
  Returns `:ok` if the message is allowed, `{:error, :throttled, retry_after_ms}` if the connection
  should be throttled, or `{:error, :throttled_exceeded}` if the connection has exceeded its limits.
  """
  @spec check_message(User.t(), String.t()) :: burst_result()
  def check_message(user, data) do
    config = Application.get_env(:elixircd, :rate_limiter)[:message]

    if message_exception?(user, config) do
      :ok
    else
      check_message_throttle(user, data, config)
    end
  end

  @spec check_message_throttle(User.t(), String.t(), keyword()) :: burst_result()
  defp check_message_throttle(user, data, config) do
    command = extract_command(data)
    pid_string = inspect(user.pid)
    override = Map.get(config[:command_throttle] || %{}, command, [])
    throttle = Keyword.merge(config[:throttle], override)

    rate_key = "#{pid_string}:#{command || "*"}"
    violation_key = "disconnect:#{rate_key}"

    refill_rate = throttle[:refill_rate]
    capacity = throttle[:capacity]
    cost = throttle[:cost]
    window_ms = throttle[:window_ms]
    disconnect_threshold = throttle[:disconnect_threshold]

    case Message.hit(rate_key, refill_rate, capacity, cost) do
      {:allow, _count} ->
        :ok

      {:deny, _timeout} ->
        retry_ms = calculate_token_wait_time(Message, rate_key, refill_rate, capacity, cost)
        handle_throttle_violation(violation_key, window_ms, disconnect_threshold, retry_ms)
    end
  end

  @spec handle_throttle_violation(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: burst_result()
  defp handle_throttle_violation(violation_key, window_ms, disconnect_threshold, retry_ms) do
    case Violation.hit(violation_key, window_ms, disconnect_threshold) do
      {:allow, count} when count >= disconnect_threshold -> {:error, :throttled_exceeded}
      {:allow, _count} -> {:error, :throttled, retry_ms}
    end
  end

  @spec message_exception?(User.t(), keyword()) :: boolean()
  defp message_exception?(user, config) do
    exceptions = Keyword.get(config, :exceptions, [])

    # Future: Use a configuration builder that normalizes the nicknames
    exception_nicknames =
      Keyword.get(exceptions, :nicknames, [])
      |> Enum.map(fn nickname -> CaseMapping.normalize(nickname) end)

    exception_umodes = Keyword.get(exceptions, :umodes, [])
    exception_masks = Keyword.get(exceptions, :masks, [])

    cond do
      # Check if identified user's nickname is in the exceptions list
      user.identified_as && CaseMapping.normalize(user.identified_as) in exception_nicknames -> true
      # Check if user's umodes match any in the exceptions list
      user.modes && Enum.any?(exception_umodes, fn umode -> umode in user.modes end) -> true
      # Check if user's host mask matches any in the exceptions list
      user.registered && Enum.any?(exception_masks, fn mask -> Protocol.match_user_mask?(user, mask) end) -> true
      # No exceptions found
      true -> false
    end
  end

  @spec extract_command(String.t()) :: String.t() | nil
  defp extract_command(data) do
    [command | _rest] = String.split(data, " ", parts: 2)

    case command do
      "" -> nil
      _ -> String.upcase(command)
    end
  end

  @spec calculate_token_wait_time(atom(), String.t(), number(), pos_integer(), pos_integer()) :: pos_integer()
  defp calculate_token_wait_time(table_name, rate_key, refill_rate, capacity, cost) do
    now = System.system_time(:second)

    case :ets.lookup(table_name, rate_key) do
      [{^rate_key, stored_level, last_update}] ->
        # Calculate current tokens (exact same logic as hit/5)
        new_tokens = trunc((now - last_update) * refill_rate)
        current_tokens = min(capacity, stored_level + new_tokens)

        # Calculate how many more tokens we need
        tokens_needed = cost - current_tokens

        if tokens_needed <= 0 do
          # We have enough tokens now
          0
        else
          # Calculate time to accumulate the needed tokens
          trunc(tokens_needed * 1000 / refill_rate)
        end
    end
  end
end
