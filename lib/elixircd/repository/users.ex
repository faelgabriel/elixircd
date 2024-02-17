defmodule ElixIRCd.Repository.Users do
  @moduledoc """
  Module for the users repository.
  """

  alias ElixIRCd.Tables.User

  @spec create(map()) :: User.t()
  def create(attrs) do
    User.new(attrs)
    |> Memento.Query.write()
  end

  @spec update(User.t(), map()) :: User.t()
  def update(user, attrs) do
    User.update(user, attrs)
    |> Memento.Query.write()
  end

  @spec delete(User.t()) :: :ok
  def delete(user) do
    Memento.Query.delete(User, user.port)
  end

  @spec get_by_port(port()) :: {:ok, User.t()} | {:error, String.t()}
  def get_by_port(port) do
    Memento.Query.read(User, port)
    |> case do
      nil -> {:error, "User port not found: #{inspect(port)}"}
      user -> {:ok, user}
    end
  end

  @spec get_by_nick(String.t()) :: {:ok, User.t()} | {:error, String.t()}
  def get_by_nick(nick) do
    Memento.Query.select(User, {:==, :nick, nick}, limit: 1)
    |> case do
      [] -> {:error, "User nick not found: #{inspect(nick)}"}
      [user] -> {:ok, user}
    end
  end

  @spec get_by_ports([port()]) :: [User.t()]
  def get_by_ports([]), do: []

  def get_by_ports(ports) do
    conditions =
      Enum.map(ports, fn port -> {:==, :port, port} end)
      |> Enum.reduce(fn condition, acc -> {:or, condition, acc} end)

    Memento.Query.select(User, conditions)
  end
end
