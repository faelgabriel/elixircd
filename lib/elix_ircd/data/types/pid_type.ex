defmodule ElixIRCd.Types.PidType do
  @moduledoc """
  Pid type for Ecto.

  This pid is a type for the socket pids.
  """

  @behaviour Ecto.Type
  @type t :: pid

  @doc """
  Returns the type.
  """
  @spec type :: atom()
  def type, do: :pid

  @doc """
  Casts the pid.
  """
  @spec cast(pid()) :: {:ok, pid()} | :error
  def cast(pid) when is_pid(pid) do
    {:ok, pid}
  end

  def cast(_), do: :error

  @doc """
  Loads the pid.
  """
  @spec load(pid()) :: {:ok, pid()} | :error
  def load(pid) when is_pid(pid) do
    {:ok, pid}
  end

  def load(_), do: :error

  @doc """
  Dumps the pid.
  """
  @spec dump(pid()) :: {:ok, pid()} | :error
  def dump(pid) when is_pid(pid) do
    {:ok, pid}
  end

  def dump(_), do: :error

  @doc """
  Embeds the pid.
  """
  @spec embed_as(atom()) :: :self
  def embed_as(_), do: :self

  @doc """
  Compares the pids.
  """
  @spec equal?(pid(), pid()) :: boolean
  def equal?(pid1, pid2) when is_pid(pid1) and is_pid(pid2) do
    pid1 == pid2
  end

  def equal?(_, _), do: false
end
