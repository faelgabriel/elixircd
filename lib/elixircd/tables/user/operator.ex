defmodule ElixIRCd.Tables.User.Operator do
  @moduledoc """
  Module for the User.Operator data structure.
  """

  defstruct [:nick, :type]

  @type t :: %__MODULE__{
          nick: String.t() | nil,
          type: String.t() | nil
        }

  @type t_attrs :: %{
          optional(:nick) => String.t() | nil,
          optional(:type) => String.t() | nil
        }

  @doc """
  Create a new operator struct.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs \\ %{}) do
    new_attrs =
      attrs
      |> Map.put_new(:nick, nil)
      |> Map.put_new(:type, nil)

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update an operator struct.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(operator, attrs) do
    struct!(operator, attrs)
  end
end
