defmodule ElixIRCd.Data.Tables.User do
  @moduledoc """
  User table.
  """

  use Memento.Table,
    attributes: [:socket, :transport, :pid, :nick, :hostname, :username, :realname, :identity],
    index: [:nick]

  @doc """
  Changeset for the user table.
  """
  @spec changeset(User.t(), map()) :: {:ok, User.t()} | {:error, String.t()}
  def changeset(user, attrs) do
    user
    |> struct!(attrs)
    |> validate_nick()
  end

  # cannot start with a number or hyphen
  # A through to Z (Lowercase and uppercase.)
  # 0 through to 9
  # `|^_-{}[] and \
  @spec validate_nick(User.t()) :: {:ok, User.t()} | {:error, String.t()}
  defp validate_nick(%__MODULE__{nick: nick} = user) do
    nick_pattern = ~r/\A[a-zA-Z\`|\^_{}\[\]\\][a-zA-Z\d\`|\^_\-{}\[\]\\]*\z/

    if !nick || Regex.match?(nick_pattern, nick) do
      {:ok, user}
    else
      {:error, "Illegal characters"}
    end
  end
end
