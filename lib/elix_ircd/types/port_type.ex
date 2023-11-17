defmodule ElixIRCd.Types.PortType do
  @moduledoc """
  Port type for Ecto.

  This port is a type for the socket ports.
  """

  @behaviour Ecto.Type
  @type t :: port

  @doc """
  Returns the type.
  """
  @spec type :: atom()
  def type, do: :port

  @doc """
  Casts the port.
  """
  @spec cast(port()) :: {:ok, port()} | :error
  def cast(port) when is_port(port) do
    {:ok, port}
  end

  def cast(_), do: :error

  @doc """
  Loads the port.
  """
  @spec load(port()) :: {:ok, port()} | :error
  def load(port) when is_port(port) do
    {:ok, port}
  end

  def load(_), do: :error

  @doc """
  Dumps the port.
  """
  @spec dump(port()) :: {:ok, port()} | :error
  def dump(port) when is_port(port) do
    {:ok, port}
  end

  def dump(_), do: :error

  @doc """
  Embeds the port.
  """
  @spec embed_as(atom()) :: :self
  def embed_as(_), do: :self

  @doc """
  Compares the ports.
  """
  @spec equal?(port(), port()) :: boolean
  def equal?(port1, port2) when is_port(port1) and is_port(port2) do
    port1 == port2
  end

  def equal?(_, _), do: false
end

# defmodule ElixIRCd.Types.PortType do
#   @moduledoc """
#   Port type for Ecto.
#   """

#   @behaviour Ecto.Type

#   @type t :: port

#   @doc """
#   Returns the type.
#   """
#   @spec type :: atom()
#   def type, do: :port

#   @doc """
#   Casts the port.
#   """
#   @spec cast(port()) :: {:ok, port()}
#   def cast(port) when is_port(port), do: {:ok, port}

#   @doc """
#   Loads the port.
#   """
#   @spec load(port()) :: {:ok, port()}
#   def load(port) when is_port(port), do: {:ok, port}

#   @doc """
#   Dumps the port.
#   """
#   @spec dump(port()) :: {:ok, port()}
#   def dump(port) when is_port(port), do: {:ok, port}

#   @doc """
#   Embeds the port.
#   """
#   @spec embed_as(atom()) :: :self
#   def embed_as(_), do: :self

#   @doc """
#   Compares the ports.
#   """
#   @spec equal?(port(), port()) :: boolean
#   def equal?(port1, port2) when is_port(port1) and is_port(port2), do: port1 == port2
# end
