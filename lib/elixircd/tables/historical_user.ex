defmodule ElixIRCd.Tables.HistoricalUser do
  @moduledoc """
  Module for the HistoricalUser table.
  """

  @enforce_keys [:nick, :hostname, :ident, :realname, :created_at]
  use Memento.Table,
    attributes: [
      :nick,
      :hostname,
      :ident,
      :realname,
      :created_at
    ],
    type: :bag

  @type t :: %__MODULE__{
          nick: String.t(),
          hostname: String.t(),
          ident: String.t(),
          realname: String.t(),
          created_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:nick) => String.t(),
          optional(:hostname) => String.t(),
          optional(:ident) => String.t(),
          optional(:realname) => String.t(),
          optional(:created_at) => DateTime.t()
        }

  @doc """
  Create a new historical user.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    new_attrs =
      attrs
      |> Map.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, new_attrs)
  end
end
