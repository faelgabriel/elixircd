defmodule ElixIRCd.Data.Contexts.UserChannel do
  @moduledoc """
  Module for the UserChannel contexts.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas.Channel
  alias ElixIRCd.Data.Schemas.User
  alias ElixIRCd.Data.Schemas.UserChannel

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
  Deletes all user_channels
  """
  @spec delete_all(list(UserChannel.t())) :: number()
  def delete_all(user_channels) do
    from(uc in UserChannel, where: uc.id in ^Enum.map(user_channels, & &1.id))
    |> Repo.delete_all()
    |> case do
      {count, _} -> count
    end
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
  Gets a user_channel for a user and channel
  """
  @spec get_by_user_and_channel(User.t(), Channel.t()) :: {:ok, UserChannel.t()} | {:error, String.t()}
  def get_by_user_and_channel(user, channel) do
    from(uc in UserChannel,
      where: uc.user_socket == ^user.socket and uc.channel_name == ^channel.name,
      preload: [:user, :channel]
    )
    |> Repo.one()
    |> case do
      nil ->
        {:error, "UserChannel not found"}

      user_channel ->
        {:ok, user_channel}
    end
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
end
