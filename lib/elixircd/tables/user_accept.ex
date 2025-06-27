defmodule ElixIRCd.Tables.UserAccept do
  @moduledoc """
  Module for the UserAccept table.
  """

  @enforce_keys [:user_pid, :accepted_user_pid, :created_at]
  use Memento.Table,
    attributes: [
      :user_pid,
      :accepted_user_pid,
      :created_at
    ],
    index: [:accepted_user_pid],
    type: :bag

  @type t :: %__MODULE__{
          user_pid: pid(),
          accepted_user_pid: pid(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:user_pid) => pid(),
          optional(:accepted_user_pid) => pid(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new user accept entry.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
