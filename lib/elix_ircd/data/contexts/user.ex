defmodule ElixIRCd.Contexts.User do
  @moduledoc """
  Module for the User contexts.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas.User

  require Logger

  @doc """
  Creates a new user
  """
  @spec create(map()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def create(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user
  """
  @spec update(User.t(), map()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def update(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user
  """
  @spec delete(User.t()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def delete(user) do
    Repo.delete(user)
  end

  @doc """
  Gets a user by socket
  """
  @spec get_by_socket(port()) :: {:ok, User.t()} | {:error, String.t()}
  def get_by_socket(socket) do
    case Repo.get_by(User, socket: socket) do
      nil -> {:error, "User not found"}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by nick
  """
  @spec get_by_nick(String.t()) :: {:ok, User.t()} | {:error, String.t()}
  def get_by_nick(nick) do
    case Repo.get_by(User, nick: nick) do
      nil -> {:error, "User not found"}
      user -> {:ok, user}
    end
  end
end
