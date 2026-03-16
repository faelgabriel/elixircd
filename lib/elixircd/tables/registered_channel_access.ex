defmodule ElixIRCd.Tables.RegisteredChannelAccess do
  @moduledoc """
  Persistent ChanServ access entries for registered channels.
  """

  alias ElixIRCd.Utils.CaseMapping

  @enforce_keys [:id, :channel_name_key, :account_name_key, :account_name, :flags, :created_at]

  use Memento.Table,
    attributes: [:id, :channel_name_key, :account_name_key, :account_name, :flags, :created_at],
    index: [:channel_name_key, :account_name_key],
    type: :set

  @type t :: %__MODULE__{
          id: {String.t(), String.t()},
          channel_name_key: String.t(),
          account_name_key: String.t(),
          account_name: String.t(),
          flags: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:channel_name_key) => String.t(),
          optional(:channel_name) => String.t(),
          optional(:account_name_key) => String.t(),
          optional(:account_name) => String.t(),
          optional(:flags) => String.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new registered channel access entry.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    normalized_attrs =
      attrs
      |> normalize_channel_name_key()
      |> normalize_account_name_key()
      |> Map.put_new(:created_at, DateTime.utc_now())
      |> Map.update!(:flags, &String.upcase/1)
      |> put_id()

    struct!(__MODULE__, normalized_attrs)
  end

  @spec normalize_channel_name_key(t_attrs()) :: t_attrs()
  defp normalize_channel_name_key(%{channel_name_key: _} = attrs), do: attrs

  defp normalize_channel_name_key(%{channel_name: channel_name} = attrs) do
    attrs
    |> Map.delete(:channel_name)
    |> Map.put(:channel_name_key, CaseMapping.normalize(channel_name))
  end

  defp normalize_channel_name_key(attrs), do: attrs

  @spec normalize_account_name_key(t_attrs()) :: t_attrs()
  defp normalize_account_name_key(%{account_name_key: _} = attrs), do: attrs

  defp normalize_account_name_key(%{account_name: account_name} = attrs) do
    Map.put(attrs, :account_name_key, CaseMapping.normalize(account_name))
  end

  defp normalize_account_name_key(attrs), do: attrs

  @spec put_id(map()) :: map()
  defp put_id(%{channel_name_key: channel_name_key, account_name_key: account_name_key} = attrs) do
    Map.put(attrs, :id, {channel_name_key, account_name_key})
  end
end
