defmodule ElixIRCd.Tables.UserChannel do
  @moduledoc """
  Module for the UserChannel table.
  """

  @enforce_keys [:uid, :channel_name_key, :modes, :created_at]
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Server.S2S.Identity

  use Memento.Table,
    attributes: [
      :id,
      :uid,
      :channel_name_key,
      :user_pid,
      :join_id,
      :joined_ms,
      :modes,
      :created_at
    ],
    index: [:uid, :user_pid, :channel_name_key],
    type: :set

  @type t :: %__MODULE__{
          id: {Identity.id(), String.t()} | nil,
          user_pid: pid() | nil,
          uid: Identity.id(),
          channel_name_key: String.t(),
          join_id: pos_integer() | nil,
          joined_ms: non_neg_integer() | nil,
          modes: [ModeRegistry.membership_mode()],
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:id) => {Identity.id(), String.t()},
          optional(:user_pid) => pid() | nil,
          optional(:uid) => Identity.id(),
          optional(:channel_name_key) => String.t(),
          optional(:join_id) => pos_integer() | nil,
          optional(:joined_ms) => non_neg_integer() | nil,
          optional(:modes) => [ModeRegistry.membership_mode()],
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new user channel.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> put_uid()
      |> Map.put_new(:modes, [])
      |> Map.put_new(:created_at, DateTime.utc_now())
      |> put_id()

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a user channel.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(user_channel, attrs) do
    user_channel
    |> Map.from_struct()
    |> Map.merge(attrs)
    |> put_id()
    |> then(&struct!(__MODULE__, &1))
  end

  defp put_uid(%{uid: uid} = attrs) when is_binary(uid), do: attrs

  defp put_uid(%{user_pid: pid} = attrs) when is_pid(pid) do
    try do
      case ElixIRCd.Repositories.Users.uid_for_pid(pid) do
        {:ok, uid} -> Map.put(attrs, :uid, uid)
        _ -> Map.put_new(attrs, :uid, Identity.uid())
      end
    catch
      :exit, _ -> Map.put_new(attrs, :uid, Identity.uid())
    end
  end

  defp put_uid(attrs), do: Map.put_new(attrs, :uid, Identity.uid())

  defp put_id(%{uid: uid, channel_name_key: channel_name_key} = attrs)
       when is_binary(uid) and is_binary(channel_name_key),
       do: Map.put(attrs, :id, {uid, channel_name_key})

  defp put_id(attrs), do: attrs
end
