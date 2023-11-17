defmodule ElixIRCd.Schemas.User do
  @moduledoc """
  Module for the User schema.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Schemas.User
  alias ElixIRCd.Schemas.UserChannel
  alias ElixIRCd.Types.PortType
  alias ElixIRCd.Types.TransportType

  import Ecto.Changeset

  use TypedEctoSchema

  @primary_key {:socket, PortType, autogenerate: false}
  typed_schema "user" do
    field(:transport, TransportType)
    field(:nick, :string)
    field(:hostname, :string)
    field(:username, :string)
    field(:realname, :string)
    field(:identity, :string)

    has_many(:user_channels, UserChannel, foreign_key: :user_socket, on_delete: :delete_all)
  end

  @doc """
  Creates a changeset for the User schema.
  """
  @spec changeset(User.t(), map()) :: Changeset.t()
  def changeset(%User{} = user, attrs) do
    user
    |> cast(attrs, [:socket, :transport, :nick, :hostname, :username, :realname, :identity])
    |> validate_required([:socket, :transport])
    |> validate_nick()
  end

  # cannot start with a number or hyphen
  # A through to Z (Lowercase and uppercase.)
  # 0 through to 9
  # `|^_-{}[] and \
  @spec validate_nick(Changeset.t()) :: Changeset.t()
  defp validate_nick(changeset) do
    nick = get_field(changeset, :nick)
    nick_pattern = ~r/\A[a-zA-Z\`|\^_{}\[\]\\][a-zA-Z\d\`|\^_\-{}\[\]\\]*\z/

    if !nick || Regex.match?(nick_pattern, nick) do
      changeset
    else
      add_error(changeset, :nick, "Illegal characters")
    end
  end
end
