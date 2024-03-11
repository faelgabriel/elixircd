defmodule ElixIRCd.Repository.Users do
  @moduledoc """
  Module for the users repository.
  """

  alias ElixIRCd.Tables.User

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
end
