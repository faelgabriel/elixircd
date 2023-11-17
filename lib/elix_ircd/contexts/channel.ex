defmodule ElixIRCd.Contexts.Channel do
  @moduledoc """
  Module for the Channel contexts.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Repo
  alias ElixIRCd.Schemas.Channel

  require Logger

  @doc """
  Creates a new channel
  """
  @spec create(map()) :: {:ok, Channel.t()} | {:error, Changeset.t()}
  def create(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a channel
  """
  @spec update(Channel.t(), map()) :: {:ok, Channel.t()} | {:error, Changeset.t()}
  def update(channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a channel
  """
  @spec delete(Channel.t()) :: :ok | {:error, Changeset.t()}
  def delete(channel) do
    Repo.delete(channel)
  end

  @doc """
  Gets a channel by name
  """
  @spec get_by_name(String.t()) :: Channel.t() | nil
  def get_by_name(name) do
    Repo.get(Channel, name)
  end
end
