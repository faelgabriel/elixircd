defmodule ElixIRCd.Tables.SaslSession do
  @moduledoc """
  Temporary table for SASL authentication sessions.

  This table stores ephemeral data during SASL authentication flow.
  Sessions are cleaned up after authentication completes or aborts.
  """

  use Memento.Table,
    attributes: [
      :user_pid,
      :mechanism,
      :buffer,
      :state,
      :created_at
    ],
    index: [],
    type: :set

  @type t :: %__MODULE__{
          user_pid: pid(),
          mechanism: String.t() | nil,
          buffer: String.t() | nil,
          state: map() | nil,
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:user_pid) => pid(),
          optional(:mechanism) => String.t() | nil,
          optional(:buffer) => String.t() | nil,
          optional(:state) => map() | nil,
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new SASL session.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:buffer, "")
      |> Map.put_new(:state, nil)
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update a SASL session.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(session, attrs) do
    struct!(session, attrs)
  end
end


