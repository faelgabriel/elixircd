defmodule ElixIRCd.Data.Tables.UserChannel do
  @moduledoc """
  UserChannel table.
  """

  use Memento.Table,
    attributes: [:user_socket, :channel_name],
    index: [:channel_name],
    type: :bag

  @doc """
  Changeset for the user_channel table.
  """
  @spec changeset(UserChannel.t(), map()) :: {:ok, UserChannel.t()} | {:error, String.t()}
  def changeset(user_channel, attrs) do
    user_channel
    |> struct!(attrs)
  end
end
