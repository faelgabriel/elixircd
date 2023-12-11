defmodule ElixIRCd.Contexts.User do
  @moduledoc """
  Module for the User contexts.
  """

  alias ElixIRCd.Data.Tables.User

  @doc """
  Creates a new user
  """
  @spec create(map()) :: {:ok, User.t()} | {:error, String.t()}
  def create(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Memento.Query.write()
    |> case do
      %User{} = user -> {:ok, user}
      error -> {:error, "User not created: #{error}"}
    end
  end

  @doc """
  Updates a user
  """
  @spec update(User.t(), map()) :: {:ok, User.t()} | {:error, String.t()}
  def update(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Memento.Query.write()
    |> case do
      %User{} = user -> {:ok, user}
      error -> {:error, "User not updated: #{error}"}
    end
  end

  @doc """
  Deletes a user
  """
  @spec delete(User.t()) :: :ok
  def delete(user) do
    Memento.Query.delete(Channel, user.socket)
  end

  @doc """
  Gets a user by socket
  """
  @spec get_by_socket(port()) :: {:ok, User.t()} | {:error, String.t()}
  def get_by_socket(socket) do
    Memento.Query.read(User, socket)
    |> case do
      %User{} = user -> {:ok, user}
      nil -> {:error, "User not found"}
    end
  end

  @doc """
  Gets a user by nick
  """
  @spec get_by_nick(String.t()) :: {:ok, User.t()} | {:error, String.t()}
  def get_by_nick(nick) do
    Memento.Query.select(User, {:==, :nick, nick})
    |> case do
      [%User{} = user] -> {:ok, user}
      [] -> {:error, "User not found"}
    end
  end
end
