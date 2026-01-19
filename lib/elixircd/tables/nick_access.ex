defmodule ElixIRCd.Tables.NickAccess do
  @moduledoc """
  Module for the NickAccess table.

  Stores access list entries for registered nicknames, containing host masks
  that are authorized to use the nickname.
  """

  alias ElixIRCd.Utils.CaseMapping

  @enforce_keys [:nickname_key, :mask, :created_at]
  use Memento.Table,
    attributes: [:nickname_key, :mask, :created_at],
    index: [],
    type: :bag

  @type t :: %__MODULE__{
          nickname_key: String.t(),
          mask: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:nickname_key) => String.t(),
          optional(:nickname) => String.t(),
          optional(:mask) => String.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new nick access entry.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> normalize_nickname_key()
      |> normalize_mask()
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end

  @spec normalize_nickname_key(t_attrs()) :: t_attrs()
  defp normalize_nickname_key(%{nickname_key: _} = attrs) do
    # nickname_key already provided, no need to normalize
    attrs
  end

  defp normalize_nickname_key(%{nickname: nickname} = attrs) do
    nickname_key = CaseMapping.normalize(nickname)
    attrs |> Map.delete(:nickname) |> Map.put(:nickname_key, nickname_key)
  end

  defp normalize_nickname_key(attrs), do: attrs

  @spec normalize_mask(t_attrs()) :: t_attrs()
  defp normalize_mask(%{mask: mask} = attrs) when is_binary(mask) do
    Map.put(attrs, :mask, String.downcase(mask))
  end

  defp normalize_mask(attrs), do: attrs
end
