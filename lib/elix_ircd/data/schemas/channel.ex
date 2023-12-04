defmodule ElixIRCd.Data.Schemas.Channel do
  @moduledoc """
  Module for the Channel schema.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Data.Schemas.Channel
  alias ElixIRCd.Data.Schemas.UserChannel

  import Ecto.Changeset

  use TypedEctoSchema

  @primary_key {:name, :string, autogenerate: false}
  typed_schema "channel" do
    field(:topic, :string)

    has_many(:user_channels, UserChannel, foreign_key: :channel_name)
  end

  @doc """
  Creates a changeset for a Channel.
  """
  @spec changeset(Channel.t(), map()) :: Changeset.t()
  def changeset(%Channel{} = channel, attrs) do
    channel
    |> cast(attrs, [:name, :topic])
    |> validate_required([:name])
    |> unique_constraint(:name, name: :primary_key)
    |> validate_name()
  end

  # starts with a hash mark (#)
  # 1 through to 49 characters
  # A through to Z (Lowercase and uppercase.)
  # 0 through to 9
  # _ and -
  @spec validate_name(Changeset.t()) :: Changeset.t()
  defp validate_name(changeset) do
    name = get_field(changeset, :name)
    name_pattern = ~r/^#[a-zA-Z0-9_\-]{1,49}$/

    cond do
      !String.starts_with?(name, "#") ->
        add_error(changeset, :name, "Channel name must start with a hash mark (#)")

      !Regex.match?(name_pattern, name) ->
        add_error(changeset, :name, "Invalid channel name format")

      true ->
        changeset
    end
  end
end
