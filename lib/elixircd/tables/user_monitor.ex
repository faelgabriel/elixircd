defmodule ElixIRCd.Tables.UserMonitor do
  @moduledoc """
  Module for the UserMonitor table.

  Stores monitor subscriptions: which users are monitoring which nicknames.
  """

  @enforce_keys [:user_pid, :target_nick_key, :created_at]
  use Memento.Table,
    attributes: [
      :user_pid,
      :target_nick_key,
      :created_at
    ],
    index: [:target_nick_key],
    type: :bag

  @type t :: %__MODULE__{
          user_pid: pid(),
          target_nick_key: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:user_pid) => pid(),
          optional(:target_nick_key) => String.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new user monitor entry.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
