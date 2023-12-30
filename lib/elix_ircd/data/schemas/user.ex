defmodule ElixIRCd.Data.Schemas.User do
  @moduledoc """
  Module for the User schema.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Data.Schemas.User
  alias ElixIRCd.Data.Schemas.UserChannel
  alias ElixIRCd.Types.PidType
  alias ElixIRCd.Types.SocketType
  alias ElixIRCd.Types.TransportType

  import Ecto.Changeset

  use TypedEctoSchema

  @primary_key {:socket, SocketType, autogenerate: false}
  typed_schema "user" do
    field(:transport, TransportType)
    field(:pid, PidType)
    field(:nick, :string)
    field(:hostname, :string)
    field(:username, :string)
    field(:realname, :string)
    field(:identity, :string)
    field(:modes, {:array, :any}, default: [])

    has_many(:user_channels, UserChannel, foreign_key: :user_socket, on_delete: :delete_all)
  end

  @doc """
  Creates a changeset for the User schema.
  """
  @spec changeset(User.t(), map()) :: Changeset.t()
  def changeset(%User{} = user, attrs) do
    user
    |> cast(attrs, [
      :socket,
      :transport,
      :pid,
      :nick,
      :hostname,
      :username,
      :realname,
      :identity,
      :modes
    ])
    |> validate_required([:socket, :transport, :pid])
    |> validate_nick()
  end

  # nick is optional since it is set when the user registers
  # cannot start with a number or hyphen
  # A through to Z (Lowercase and uppercase.)
  # 0 through to 9
  # `|^_-{}[] and \
  @spec validate_nick(Changeset.t()) :: Changeset.t()
  defp validate_nick(changeset) do
    nick = get_field(changeset, :nick)
    max_nick_length = 30
    nick_pattern = ~r/\A[a-zA-Z\`|\^_{}\[\]\\][a-zA-Z\d\`|\^_\-{}\[\]\\]*\z/

    cond do
      is_nil(nick) -> changeset
      String.length(nick) > max_nick_length -> add_error(changeset, :nick, "Nickname too long")
      !Regex.match?(nick_pattern, nick) -> add_error(changeset, :nick, "Illegal characters")
      true -> changeset
    end
  end
end
