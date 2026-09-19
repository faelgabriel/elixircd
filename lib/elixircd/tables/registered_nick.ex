defmodule ElixIRCd.Tables.RegisteredNick do
  @moduledoc """
  Module for the RegisteredNick table.
  """

  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Utils.CaseMapping

  @enforce_keys [
    :nickname_key,
    :nickname,
    :account_name_key,
    :account_name,
    :password_hash,
    :registered_by,
    :created_at
  ]
  use Memento.Table,
    attributes: [
      :nickname_key,
      :nickname,
      :account_name_key,
      :account_name,
      :password_hash,
      :email,
      :registered_by,
      :verify_code,
      :verified_at,
      :pending_email,
      :pending_email_verify_code,
      :pending_email_requested_at,
      :last_seen_at,
      :reserved_until,
      :settings,
      :created_at
    ],
    index: [:account_name_key],
    type: :set

  @type t :: %__MODULE__{
          nickname_key: String.t(),
          nickname: String.t(),
          account_name_key: String.t(),
          account_name: String.t(),
          password_hash: String.t(),
          email: String.t() | nil,
          registered_by: String.t(),
          verify_code: String.t() | nil,
          verified_at: DateTime.t() | nil,
          pending_email: String.t() | nil,
          pending_email_verify_code: String.t() | nil,
          pending_email_requested_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          reserved_until: DateTime.t() | nil,
          settings: Settings.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:nickname) => String.t(),
          optional(:account_name) => String.t(),
          optional(:password_hash) => String.t(),
          optional(:email) => String.t() | nil,
          optional(:registered_by) => String.t(),
          optional(:verify_code) => String.t() | nil,
          optional(:verified_at) => DateTime.t() | nil,
          optional(:pending_email) => String.t() | nil,
          optional(:pending_email_verify_code) => String.t() | nil,
          optional(:pending_email_requested_at) => DateTime.t() | nil,
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
      |> put_default_account_name()
      |> handle_keys()

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a registered nickname.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(registered_nick, attrs) do
    new_attrs =
      attrs
      |> put_default_account_name()
      |> handle_keys()

    struct!(registered_nick, new_attrs)
  end

  @spec put_default_account_name(t_attrs()) :: t_attrs()
  defp put_default_account_name(%{account_name: _account_name} = attrs), do: attrs

  defp put_default_account_name(%{nickname: nickname} = attrs) do
    Map.put(attrs, :account_name, nickname)
  end

  defp put_default_account_name(attrs), do: attrs

  @spec handle_keys(t_attrs()) :: t_attrs()
  defp handle_keys(attrs) do
    attrs
    |> maybe_put_normalized_key(:nickname, :nickname_key)
    |> maybe_put_normalized_key(:account_name, :account_name_key)
  end

  @spec maybe_put_normalized_key(t_attrs(), atom(), atom()) :: t_attrs()
  defp maybe_put_normalized_key(attrs, source_key, target_key) do
    case Map.fetch(attrs, source_key) do
      {:ok, value} when is_binary(value) -> Map.put(attrs, target_key, CaseMapping.normalize(value))
      _ -> attrs
    end
  end
end
