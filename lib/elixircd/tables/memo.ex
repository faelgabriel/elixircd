defmodule ElixIRCd.Tables.Memo do
  @moduledoc """
  Persistent NickServ memo delivered to a registered account.

  Memos are account-owned rather than nickname-owned, so grouped nicknames
  share one inbox.
  """

  @enforce_keys [:id, :recipient_account_key, :recipient_account, :sender_account, :body, :created_at]

  alias ElixIRCd.Utils.CaseMapping

  use Memento.Table,
    attributes: [
      :id,
      :recipient_account_key,
      :recipient_account,
      :sender_account,
      :body,
      :read_at,
      :created_at
    ],
    index: [:recipient_account_key],
    type: :set

  @type t :: %__MODULE__{
          id: String.t(),
          recipient_account_key: String.t(),
          recipient_account: String.t(),
          sender_account: String.t(),
          body: String.t(),
          read_at: DateTime.t() | nil,
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:id) => String.t(),
          optional(:recipient_account_key) => String.t(),
          optional(:recipient_account) => String.t(),
          optional(:sender_account) => String.t(),
          optional(:body) => String.t(),
          optional(:read_at) => DateTime.t() | nil,
          optional(:created_at) => DateTime.t()
        }

  @doc "Creates a memo with a unique identifier and normalized account key."
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    attrs
    |> normalize_recipient_key()
    |> Map.put_new(:id, generate_id())
    |> Map.put_new(:read_at, nil)
    |> Map.put_new(:created_at, DateTime.utc_now())
    |> then(&struct!(__MODULE__, &1))
  end

  @doc "Updates a memo without changing its identifier."
  @spec update(t(), t_attrs()) :: t()
  def update(memo, attrs), do: struct!(memo, attrs)

  @spec normalize_recipient_key(t_attrs()) :: t_attrs()
  defp normalize_recipient_key(%{recipient_account_key: _key} = attrs), do: attrs

  defp normalize_recipient_key(%{recipient_account: account} = attrs) do
    Map.put(attrs, :recipient_account_key, CaseMapping.normalize(account))
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end
end
