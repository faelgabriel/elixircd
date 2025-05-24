defmodule ElixIRCd.Tables.RegisteredNick do
  @moduledoc """
  Module for the RegisteredNick table.
  """

  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Utils.CaseMapping

  @enforce_keys [:nickname_key, :nickname, :password_hash, :registered_by, :created_at]
  use Memento.Table,
    attributes: [
      :nickname_key,
      :nickname,
      :password_hash,
      :email,
      :registered_by,
      :verify_code,
      :verified_at,
      :last_seen_at,
      :reserved_until,
      :settings,
      :created_at
    ],
    index: [],
    type: :set

  @type t :: %__MODULE__{
          nickname_key: String.t(),
          nickname: String.t(),
          password_hash: String.t(),
          email: String.t() | nil,
          registered_by: String.t(),
          verify_code: String.t() | nil,
          verified_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          reserved_until: DateTime.t() | nil,
          settings: Settings.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:nickname) => String.t(),
          optional(:password_hash) => String.t(),
          optional(:email) => String.t() | nil,
          optional(:registered_by) => String.t(),
          optional(:verify_code) => String.t() | nil,
          optional(:verified_at) => DateTime.t() | nil,
          optional(:last_seen_at) => DateTime.t() | nil,
          optional(:reserved_until) => DateTime.t() | nil,
          optional(:settings) => Settings.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new registered nickname.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:settings, Settings.new())
      |> Map.put_new(:created_at, DateTime.utc_now())
      |> handle_nickname_key()

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a registered nickname.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(registered_nick, attrs) do
    new_attrs =
      attrs
      |> handle_nickname_key()

    struct!(registered_nick, new_attrs)
  end

  @spec handle_nickname_key(t_attrs()) :: t_attrs()
  defp handle_nickname_key(%{nickname: nickname} = attrs) do
    nickname_key = if nickname != nil, do: CaseMapping.normalize(nickname), else: nil
    Map.put(attrs, :nickname_key, nickname_key)
  end

  defp handle_nickname_key(attrs), do: attrs
end
