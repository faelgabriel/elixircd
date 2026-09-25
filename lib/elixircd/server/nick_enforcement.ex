defmodule ElixIRCd.Server.NickEnforcement do
  @moduledoc """
  Coordinates NickServ nickname enforcement and owns its runtime timers.

  This module resolves the current account policy, reconciles enforcement when
  nickname or authentication state changes, persists timer deadlines on the
  in-memory user row, and applies the configured result when enforcement expires.
  """

  use GenServer

  import ElixIRCd.Utils.Nickserv, only: [belongs_to_account?: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.NickChange
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Tables.User

  @name __MODULE__

  @type timer_entry :: %{
          timer_ref: reference(),
          token: reference(),
          nick_key: String.t()
        }
  @type state :: %{optional(pid()) => timer_entry()}
  @type rejection_action :: :reject | :disconnect

  @doc "Starts the supervised nickname-enforcement timer owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, @name))
  end

  @doc "Schedules or replaces a user's pending nickname enforcement action."
  @spec schedule(pid(), String.t(), non_neg_integer()) :: :ok | {:error, :not_started | :invalid_delay}
  def schedule(pid, nick_key, delay_seconds)
      when is_pid(pid) and is_binary(nick_key) and is_integer(delay_seconds) and delay_seconds >= 0 do
    cond do
      delay_seconds > max_delay_seconds() -> {:error, :invalid_delay}
      Process.whereis(@name) -> GenServer.cast(@name, {:schedule, pid, nick_key, delay_seconds})
      true -> {:error, :not_started}
    end
  end

  def schedule(_pid, _nick_key, _delay_seconds), do: {:error, :invalid_delay}

  @doc "Cancels all pending enforcement for a connection."
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    if Process.whereis(@name), do: GenServer.cast(@name, {:cancel, pid})
    :ok
  end

  @doc "Returns whether a grace timer currently protects the given nickname."
  @spec grace_active?(pid(), String.t()) :: boolean()
  def grace_active?(pid, nick_key) when is_pid(pid) and is_binary(nick_key) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:grace_active?, pid, nick_key})
    else
      false
    end
  end

  @doc "Returns whether the supervised enforcement service is available."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(@name))

  @doc "Checks whether a connection may assume a NickServ-protected nickname."
  @spec authorize_nick(User.t(), String.t()) :: :ok | {:error, {:nick_enforced, rejection_action()}}
  def authorize_nick(user, input_nick) do
    with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(input_nick),
         false <- belongs_to_account?(registered_nick, user.identified_as),
         {:ok, account_nick} <- RegisteredNicks.get_by_nickname(registered_nick.account_name),
         true <- account_nick.settings.enforce,
         false <- grace_allowed?(user, registered_nick, account_nick) do
      action = if account_nick.settings.kill in [:on, :quick, :immed], do: :disconnect, else: :reject
      {:error, {:nick_enforced, action}}
    else
      _ -> :ok
    end
  end

  @doc "Applies the configured rejection response for a protected nickname."
  @spec reject_nick(User.t(), String.t(), rejection_action()) :: :ok
  def reject_nick(user, input_nick, action) do
    Observability.defer([:security], %{count: 1}, %{action: :nick_enforcement, result: action})
    send_enforced_nick_error(user, input_nick)

    if action == :disconnect do
      Dispatcher.disconnect(user, "Nickname #{input_nick} is reserved and enforced by NickServ")
    end

    :ok
  end

  @doc "Reconciles nickname enforcement after a nick or account-state change."
  @spec schedule_enforcement(User.t()) :: :ok
  def schedule_enforcement(%User{nick: nick} = user) when is_binary(nick) do
    with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(nick),
         {:ok, account_nick} <- RegisteredNicks.get_by_nickname(registered_nick.account_name),
         false <- belongs_to_account?(registered_nick, user.identified_as),
         true <- account_nick.settings.enforce do
      schedule_or_apply_enforcement(user, registered_nick, account_nick)
    else
      _ -> clear_enforcement(user)
    end

    :ok
  end

  def schedule_enforcement(%User{} = user) do
    clear_enforcement(user)
    :ok
  end

  @doc "Returns whether the current connection is allowed to use a protected nickname during its grace period."
  @spec grace_allowed?(User.t(), RegisteredNick.t(), RegisteredNick.t()) :: boolean()
  def grace_allowed?(user, registered_nick, account_nick) do
    enforce_time = enforcement_delay(account_nick.settings)

    running?() and enforce_time > 0 and
      (user.nick_key != registered_nick.nickname_key or
         grace_active?(user.pid, registered_nick.nickname_key))
  end

  @impl true
  @spec init(state()) :: {:ok, state(), {:continue, :restore}}
  def init(state), do: {:ok, state, {:continue, :restore}}

  @impl true
  def handle_continue(:restore, state) do
    users = transaction(fn -> Users.get_all() end)
    now = DateTime.utc_now()

    restored_state = Enum.reduce(users, state, &restore_user_timer(&2, &1, now))
    {:noreply, restored_state}
  end

  @impl true
  def handle_cast({:schedule, pid, nick_key, delay_seconds}, state) do
    state = cancel_timer(state, pid)
    state = put_timer(state, pid, nick_key, delay_seconds * 1_000)
    {:noreply, state}
  end

  def handle_cast({:cancel, pid}, state), do: {:noreply, cancel_timer(state, pid)}

  @impl true
  def handle_call({:grace_active?, pid, nick_key}, _from, state) do
    active? = match?(%{nick_key: ^nick_key}, Map.get(state, pid))
    {:reply, active?, state}
  end

  @impl true
  def handle_info({:expire, pid, nick_key, token}, state) do
    case Map.get(state, pid) do
      %{nick_key: ^nick_key, token: ^token} ->
        state = Map.delete(state, pid)

        transaction(fn ->
          clear_persisted_timer(pid, nick_key)
          enforce_expired(pid, nick_key)
        end)

        {:noreply, state}

      # This race is only reachable after the runtime has delivered a timer that
      # was already canceled; exercising it would require bypassing the public API.
      # coveralls-ignore-next-line
      _stale_or_replaced_timer ->
        {:noreply, state}
    end
  end

  @spec restore_user_timer(state(), User.t(), DateTime.t()) :: state()
  defp restore_user_timer(
         state,
         %User{
           pid: pid,
           nick_enforcement_key: nick_key,
           nick_enforcement_deadline_at: %DateTime{} = deadline_at
         },
         now
       )
       when is_binary(nick_key) do
    remaining_ms = max(DateTime.diff(deadline_at, now, :millisecond), 0)
    put_timer(state, pid, nick_key, remaining_ms)
  end

  defp restore_user_timer(state, _user, _now), do: state

  @spec schedule_or_apply_enforcement(User.t(), RegisteredNick.t(), RegisteredNick.t()) :: :ok
  defp schedule_or_apply_enforcement(user, registered_nick, account_nick) do
    enforce_time = enforcement_delay(account_nick.settings)

    cond do
      enforce_time == 0 ->
        clear_enforcement(user)
        enforce_expired(user.pid, registered_nick.nickname_key)

      grace_active?(user.pid, registered_nick.nickname_key) ->
        :ok

      true ->
        deadline_at = DateTime.add(DateTime.utc_now(), enforce_time, :second)

        scheduled_user =
          Users.update(user, %{
            nick_enforcement_key: registered_nick.nickname_key,
            nick_enforcement_deadline_at: deadline_at
          })

        case schedule(user.pid, registered_nick.nickname_key, enforce_time) do
          :ok ->
            send_enforcement_warning(user, enforce_time, account_nick.settings.kill)

          {:error, _reason} ->
            clear_enforcement(scheduled_user)
            enforce_expired(user.pid, registered_nick.nickname_key)
        end
    end
  end

  @spec clear_enforcement(User.t()) :: :ok
  defp clear_enforcement(user) do
    cancel(user.pid)

    if user.nick_enforcement_key || user.nick_enforcement_deadline_at do
      Users.update(user, %{
        nick_enforcement_key: nil,
        nick_enforcement_deadline_at: nil
      })
    end

    :ok
  end

  @spec enforcement_delay(Settings.t()) :: non_neg_integer()
  defp enforcement_delay(settings) do
    nickserv = Application.fetch_env!(:elixircd, :services)[:nickserv]
    configured_time = min(settings.enforce_time, nickserv[:max_enforce_time])

    case settings.kill do
      :immed -> 0
      :quick -> min(configured_time, nickserv[:quick_enforce_time])
      _other -> configured_time
    end
  end

  @spec send_enforcement_warning(User.t(), pos_integer(), atom()) :: :ok
  defp send_enforcement_warning(user, enforce_time, kill_mode) do
    consequence = if kill_mode == :off, do: "your nickname will be changed", else: "you will be disconnected"

    %Message{
      command: "NOTICE",
      params: [user.nick],
      trailing:
        "This nickname is registered and protected. Identify to its account within #{enforce_time} seconds or #{consequence}."
    }
    |> Dispatcher.broadcast(:nickserv, user)
  end

  @doc "Applies the action for an expired NickServ enforcement timer."
  @spec enforce_expired(pid(), String.t()) :: :ok
  def enforce_expired(pid, nick_key) do
    with {:ok, user} <- Users.get_by_pid(pid),
         true <- user.nick_key == nick_key,
         {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(user.nick),
         false <- belongs_to_account?(registered_nick, user.identified_as),
         {:ok, account_nick} <- RegisteredNicks.get_by_nickname(registered_nick.account_name),
         true <- account_nick.settings.enforce do
      case account_nick.settings.kill do
        kill when kill in [:quick, :immed, :on] -> reject_nick(user, user.nick, :disconnect)
        _other -> force_guest_nick(user)
      end
    else
      _ -> :ok
    end

    :ok
  end

  @spec force_guest_nick(User.t()) :: :ok
  defp force_guest_nick(user) do
    Observability.defer([:security], %{count: 1}, %{action: :nick_enforcement, result: :rename})
    NickChange.change(user, available_guest_nick())
    :ok
  end

  @spec available_guest_nick() :: String.t()
  defp available_guest_nick do
    candidate = "Guest" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    with {:error, :user_not_found} <- Users.get_by_nick(candidate),
         {:error, :registered_nick_not_found} <- RegisteredNicks.get_by_nickname(candidate) do
      candidate
    else
      _collision -> available_guest_nick()
    end
  end

  @spec send_enforced_nick_error(User.t(), String.t()) :: :ok
  defp send_enforced_nick_error(user, input_nick) do
    %Message{
      command: :err_nicknameinuse,
      params: [ElixIRCd.Utils.Protocol.user_reply(user), input_nick],
      trailing: "Nickname is reserved and enforced by NickServ"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec put_timer(state(), pid(), String.t(), non_neg_integer()) :: state()
  defp put_timer(state, pid, nick_key, delay_ms) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:expire, pid, nick_key, token}, delay_ms)

    Map.put(state, pid, %{
      timer_ref: timer_ref,
      token: token,
      nick_key: nick_key
    })
  end

  @spec cancel_timer(state(), pid()) :: state()
  defp cancel_timer(state, pid) do
    case Map.pop(state, pid) do
      {nil, state} ->
        state

      {%{timer_ref: timer_ref}, state} ->
        Process.cancel_timer(timer_ref)
        state
    end
  end

  @spec clear_persisted_timer(pid(), String.t()) :: :ok
  defp clear_persisted_timer(pid, expected_nick_key) do
    transaction(fn ->
      with {:ok, user} <- Users.get_by_pid(pid),
           true <- user.nick_enforcement_key == expected_nick_key do
        Users.update(user, %{nick_enforcement_key: nil, nick_enforcement_deadline_at: nil})
      end
    end)

    :ok
  end

  @spec transaction((-> result)) :: result when result: var
  defp transaction(operation) do
    if Memento.Transaction.inside?(), do: operation.(), else: Observability.transaction(operation)
  end

  @spec max_delay_seconds() :: pos_integer()
  defp max_delay_seconds do
    Application.fetch_env!(:elixircd, :services)[:nickserv][:max_enforce_time]
  end
end
