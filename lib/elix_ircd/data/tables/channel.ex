defmodule ElixIRCd.Data.Tables.Channel do
  @moduledoc """
  Channel table.
  """

  use Memento.Table,
    attributes: [:name, :topic]

  @doc """
  Changeset for the channel table.
  """
  @spec changeset(Channel.t(), map()) :: {:ok, Channel.t()} | {:error, String.t()}
  def changeset(channel, attrs) do
    channel
    |> struct!(attrs)
    |> validate_name()
  end

  # starts with a hash mark (#)
  # 1 through to 49 characters
  # A through to Z (Lowercase and uppercase.)
  # 0 through to 9
  # _ and -
  @spec validate_name(Channel.t()) :: {:ok, Channel.t()} | {:error, String.t()}
  defp validate_name(%__MODULE__{name: name} = channel) do
    cond do
      !String.starts_with?(name, "#") ->
        {:error, "Channel name must start with a hash mark (#)"}

      !Regex.match?(~r/^#[a-zA-Z0-9_\-]{1,49}$/, name) ->
        {:error, "Invalid channel name format"}

      true ->
        channel
    end
  end
end
