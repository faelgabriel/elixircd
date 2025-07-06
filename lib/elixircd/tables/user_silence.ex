defmodule ElixIRCd.Tables.UserSilence do
  @moduledoc """
  Table for storing user silence lists.
  """

  @enforce_keys [:user_pid, :mask, :created_at]
  use Memento.Table,
    attributes: [:user_pid, :mask, :created_at],
    index: [],
    type: :bag

  @type t :: %__MODULE__{
          user_pid: pid(),
          mask: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:user_pid) => pid(),
          optional(:mask) => String.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new user silence entry.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
