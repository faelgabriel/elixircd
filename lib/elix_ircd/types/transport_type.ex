defmodule ElixIRCd.Types.TransportType do
  @moduledoc """
  Transport type for Ecto.

  This transport is a type for the ranch transports.
  """

  @behaviour Ecto.Type
  @type t :: :ranch_tcp | :ranch_ssl

  @doc """
  Returns the type.
  """
  @spec type :: atom()
  def type, do: :string

  @doc """
  Casts the transport.
  """
  @spec cast(atom()) :: {:ok, t()} | :error
  def cast(:ranch_tcp), do: {:ok, :ranch_tcp}
  def cast(:ranch_ssl), do: {:ok, :ranch_ssl}
  def cast(_), do: :error

  @doc """
  Loads the transport.
  """
  @spec load(String.t()) :: {:ok, t()} | :error
  def load("ranch_tcp"), do: {:ok, :ranch_tcp}
  def load("ranch_ssl"), do: {:ok, :ranch_ssl}
  def load(_), do: :error

  @doc """
  Dumps the transport.
  """
  @spec dump(t()) :: {:ok, String.t()} | :error
  def dump(:ranch_tcp), do: {:ok, "ranch_tcp"}
  def dump(:ranch_ssl), do: {:ok, "ranch_ssl"}
  def dump(_), do: :error

  @doc """
  Defines how the type should be embedded in a parent structure.
  """
  @spec embed_as(atom()) :: :self
  def embed_as(_), do: :self

  @doc """
  Compares the transports.
  """
  @spec equal?(t(), t()) :: boolean
  def equal?(nil, _), do: false
  def equal?(_, nil), do: false
  def equal?(transport1, transport2), do: transport1 == transport2
end
