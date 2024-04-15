defmodule ElixIRCd.Repository.Users do
  @moduledoc """
  Module for the users repository.
  """

  import ElixIRCd.Helper, only: [user_mask_match?: 2]

  alias ElixIRCd.Tables.User
  alias Memento.Query.Data

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
    User.update(user, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a user from the database.
  """
  @spec delete(User.t()) :: :ok
  def delete(user) do
    Memento.Query.delete(User, user.port)
  end

  @doc """
  Get a user by the port.
  """
  @spec get_by_port(port()) :: {:ok, User.t()} | {:error, atom()}
  def get_by_port(port) do
    Memento.Query.read(User, port)
    |> case do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Get a user by the nick.
  """
  @spec get_by_nick(String.t()) :: {:ok, User.t()} | {:error, atom()}
  def get_by_nick(nick) do
    Memento.Query.select(User, {:==, :nick, nick}, limit: 1)
    |> case do
      [] -> {:error, :user_not_found}
      [user] -> {:ok, user}
    end
  end

  @doc """
  Get all users by the ports.
  """
  @spec get_by_ports([port()]) :: [User.t()]
  def get_by_ports([]), do: []

  def get_by_ports(ports) do
    conditions =
      Enum.map(ports, fn port -> {:==, :port, port} end)
      |> Enum.reduce(fn condition, acc -> {:or, condition, acc} end)

    Memento.Query.select(User, conditions)
  end

  @doc """
  Get all users that match the mask.
  """
  @spec get_by_match_mask(String.t()) :: [User.t()]
  def get_by_match_mask(mask) do
    Memento.Query.all(User)
    # Future: Use Mnesia foldl to filter users by mask.
    |> Enum.filter(fn user -> user_mask_match?(user, mask) end)
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
    # Eventually: optimize this for large datasets
    :mnesia.foldl(
      fn raw_user, acc ->
        user = Data.load(raw_user)

        visible = if user.registered and "i" not in user.modes, do: acc.visible + 1, else: acc.visible
        invisible = if user.registered and "i" in user.modes, do: acc.invisible + 1, else: acc.invisible
        operators = if user.registered and "o" in user.modes, do: acc.operators + 1, else: acc.operators
        unknown = if user.registered, do: acc.unknown, else: acc.unknown + 1

        %{acc | visible: visible, invisible: invisible, operators: operators, unknown: unknown, total: acc.total + 1}
      end,
      %{visible: 0, invisible: 0, operators: 0, unknown: 0, total: 0},
      User
    )
  end
end
