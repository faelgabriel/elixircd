defmodule ElixIRCd.Tables.RegisteredNick do
  @moduledoc """
  Module for the RegisteredNick table.
  """

  @enforce_keys [:nickname, :password_hash, :registered_by, :created_at]
  use Memento.Table,
    attributes: [
      :nickname,
      :password_hash,
      :email,
      :registered_by,
      :last_seen_at,
      :created_at,
      :verify_code
    ],
    index: [],
    type: :set

  @type t :: %__MODULE__{
          nickname: String.t(),
          password_hash: String.t(),
          email: String.t() | nil,
          registered_by: String.t(),
          verify_code: String.t() | nil,
          last_seen_at: DateTime.t() | nil,
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:nickname) => String.t(),
          optional(:password_hash) => String.t(),
          optional(:email) => String.t() | nil,
          optional(:registered_by) => String.t(),
          optional(:verify_code) => String.t() | nil,
          optional(:last_seen_at) => DateTime.t() | nil,
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new registered nickname.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a registered nickname.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(registered_nick, attrs) do
    struct!(registered_nick, attrs)
  end
end
