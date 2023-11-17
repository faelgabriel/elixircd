defmodule ElixIRCd.Contexts.User do
  @moduledoc """
  Module for the User contexts.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Repo
  alias ElixIRCd.Schemas.User

  require Logger

  import Ecto.Query

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
  @spec delete(User.t()) :: :ok | {:error, Changeset.t()}
  def delete(user) do
    Repo.delete(user)
  end

  @doc """
  Gets a user by socket
  """
  @spec get_by_socket(port()) :: User.t() | nil
  def get_by_socket(socket) do
    Repo.get(User, socket)
  end

  @doc """
  Gets a user by nick
  """
  @spec get_by_nick(String.t()) :: User.t() | nil
  def get_by_nick(nick) do
    from(u in User, where: u.nick == ^nick)
    |> Repo.one()
  end
end
