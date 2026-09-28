defmodule ElixIRCd.Repositories.Users do
  @moduledoc """
  Module for the users repository.
  """

  import ElixIRCd.Utils.Protocol, only: [match_user_mask?: 2]

  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

  @match_all List.duplicate(:_, length(User.__info__().attributes)) |> List.to_tuple()
  @nick_key_position Enum.find_index(User.__info__().attributes, fn attr -> attr == :nick_key end)
  @account_key_position Enum.find_index(User.__info__().attributes, fn attr -> attr == :identified_as_key end)

  @doc """
  Create a new user and write it to the database.
  """
  @spec create(map()) :: User.t()
  def create(attrs) do
    User.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Update a user and write it to the database.
  """
  @spec update(User.t(), map()) :: User.t()
  def update(user, attrs) do
    updated_user = user |> User.update(attrs) |> Memento.Query.write()

    if is_nil(user.identified_as_key) and is_binary(updated_user.identified_as_key) do
      ElixIRCd.Metadata.migrate_to_account(updated_user)
      ElixIRCd.ReadMarkers.migrate_to_account(user, updated_user)
    end

    updated_user
  end

  @doc """
  Delete a user from the database.
  """
  @spec delete(User.t()) :: :ok
  def delete(user) do
    Memento.Query.delete(User, user.pid)
  end

  @doc """
  Get all users.
  """
  @spec get_all() :: [User.t()]
  def get_all do
    Memento.Query.all(User)
  end

  @doc "Reads and write locks a user by pid inside the caller transaction."
  @spec lock_by_pid(pid()) :: User.t() | nil
  def lock_by_pid(pid), do: Memento.Query.read(User, pid, lock: :write)

  @doc """
  Get a user by the pid.
  """
  @spec get_by_pid(pid()) :: {:ok, User.t()} | {:error, :user_not_found}
  def get_by_pid(pid) do
    Memento.Query.read(User, pid)
    |> case do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Get a user by the nick.
  """
  @spec get_by_nick(String.t()) :: {:ok, User.t()} | {:error, :user_not_found}
  def get_by_nick(nick) do
    nick_key = CaseMapping.normalize(nick)

    Memento.Query.match(User, put_elem(@match_all, @nick_key_position, nick_key))
    |> case do
      [] -> {:error, :user_not_found}
      [user | _] -> {:ok, user}
    end
  end

  @doc """
  Get all users identified to the given account.
  """
  @spec get_by_identified_as(String.t()) :: [User.t()]
  def get_by_identified_as(account_name) do
    identified_as_key = CaseMapping.normalize(account_name)

    Memento.Query.match(User, put_elem(@match_all, @account_key_position, identified_as_key))
  end

  @doc "Get users without an identified account using the existing account index."
  @spec get_unidentified() :: [User.t()]
  def get_unidentified do
    Memento.Query.match(User, put_elem(@match_all, @account_key_position, nil))
  end

  @doc """
  Get all users by the pids.
  """
  @spec get_by_pids([pid()]) :: [User.t()]
  def get_by_pids([]), do: []

  def get_by_pids(pids) do
    pids
    |> Enum.uniq()
    |> Enum.map(&Memento.Query.read(User, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Get all users by the nicks.
  """
  @spec get_by_nicks([String.t()]) :: [User.t()]
  def get_by_nicks([]), do: []

  def get_by_nicks(nicks) do
    nicks
    |> Enum.map(&CaseMapping.normalize/1)
    |> Enum.uniq()
    |> Enum.flat_map(&Memento.Query.match(User, put_elem(@match_all, @nick_key_position, &1)))
  end

  @doc """
  Get all users that match the mask.
  """
  @spec get_by_match_mask(String.t()) :: [User.t()]
  def get_by_match_mask(mask) do
    :mnesia.foldl(
      fn raw_user, acc ->
        user = Data.load(raw_user)

        if match_user_mask?(user, mask) do
          [user | acc]
        else
          acc
        end
      end,
      [],
      User
    )
    |> Enum.reverse()
  end

  @doc """
  Get all users by the mode.
  """
  @spec get_by_mode(ElixIRCd.ModeRegistry.user_mode()) :: [User.t()]
  def get_by_mode(mode) do
    :mnesia.foldl(
      fn raw_user, acc ->
        user = Data.load(raw_user)
        if user.registered and mode in user.modes, do: [user | acc], else: acc
      end,
      [],
      User
    )
  end

  @doc """
  Count users by ip address.
  """
  @spec count_by_ip_address(:inet.ip_address()) :: integer()
  def count_by_ip_address(ip_address) do
    :mnesia.index_read(User, ip_address, :ip_address)
    |> Enum.count()
  end

  @doc """
  Get all users that share at least one channel with the given user and have a specific capability.
  """
  @spec get_in_shared_channels_with_capability(User.t(), String.t(), include_self :: boolean()) :: [User.t()]
  def get_in_shared_channels_with_capability(user, capability, include_self \\ false) do
    user_channel_name_keys =
      UserChannels.get_by_user_pid(user.pid)
      |> Enum.map(& &1.channel_name_key)

    shared_user_pids =
      UserChannels.get_by_channel_names(user_channel_name_keys)
      |> Enum.map(& &1.user_pid)
      |> Enum.uniq()

    get_by_pids(shared_user_pids)
    |> Enum.filter(fn other_user ->
      has_capability = capability in other_user.capabilities
      is_self = other_user.pid == user.pid

      if include_self do
        has_capability
      else
        has_capability and not is_self
      end
    end)
  end

  @doc """
  Count all users.
  """
  @spec count_all() :: integer()
  def count_all, do: :mnesia.foldl(fn _raw_user, acc -> acc + 1 end, 0, User)

  @doc """
  Count all users and state types.
  """
  @spec count_all_states :: %{
          visible: integer(),
          invisible: integer(),
          operators: integer(),
          unknown: integer(),
          total: integer()
        }
  def count_all_states do
    :mnesia.foldl(
      fn raw_user, acc ->
        user = Data.load(raw_user)

        visible = if user.registered and :i not in user.modes, do: acc.visible + 1, else: acc.visible
        invisible = if user.registered and :i in user.modes, do: acc.invisible + 1, else: acc.invisible
        operators = if user.registered and :o in user.modes, do: acc.operators + 1, else: acc.operators
        unknown = if user.registered, do: acc.unknown, else: acc.unknown + 1

        %{acc | visible: visible, invisible: invisible, operators: operators, unknown: unknown, total: acc.total + 1}
      end,
      %{visible: 0, invisible: 0, operators: 0, unknown: 0, total: 0},
      User
    )
  end
end
