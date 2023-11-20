defmodule ElixIRCd.Contexts.UserChannel do
  @moduledoc """
  Module for the UserChannel contexts.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Repo
  alias ElixIRCd.Schemas.Channel
  alias ElixIRCd.Schemas.User
  alias ElixIRCd.Schemas.UserChannel

  require Logger

  import Ecto.Query

  @doc """
  Creates a new user_channel
  """
  @spec create(map()) :: {:ok, UserChannel.t()} | {:error, Changeset.t()}
  def create(attrs) do
    %UserChannel{}
    |> UserChannel.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a user_channel
  """
  @spec delete(UserChannel.t()) :: {:ok, UserChannel.t()} | {:error, Changeset.t()}
  def delete(user_channel) do
    Repo.delete(user_channel)
  end

  @doc """
  Deletes all user_channel
  """
  @spec delete_all(list(UserChannel.t())) :: {integer(), nil}
  def delete_all(user_channels) do
    ids = Enum.map(user_channels, & &1.id)
    query = from(u in UserChannel, where: u.id in ^ids)
    Repo.delete_all(query)
  end

  @doc """
  Updates a user_channel
  """
  @spec update(UserChannel.t(), map()) :: {:ok, UserChannel.t()} | {:error, Changeset.t()}
  def update(user_channel, attrs) do
    user_channel
    |> UserChannel.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets all user_channel for a user
  """
  @spec get_by_user(User.t()) :: list(UserChannel.t())
  def get_by_user(user) do
    from(uc in UserChannel, where: uc.user_socket == ^user.socket, preload: [:user, :channel])
    |> Repo.all()
  end

  @doc """
  Gets all user_channel for a channel
  """
  @spec get_by_channel(Channel.t()) :: list(UserChannel.t())
  def get_by_channel(channel) do
    from(uc in UserChannel, where: uc.channel_name == ^channel.name, preload: [:user, :channel])
    |> Repo.all()
  end

  @doc """
  Gets a user_channel for a user and channel
  """
  @spec get_by_user_and_channel(User.t(), Channel.t()) :: UserChannel.t()
  def get_by_user_and_channel(user, channel) do
    from(uc in UserChannel,
      where: uc.user_socket == ^user.socket and uc.channel_name == ^channel.name,
      preload: [:user, :channel]
    )
    |> Repo.one()
  end
end
