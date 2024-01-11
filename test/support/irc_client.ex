defmodule ElixIRCd.IrcClient do
  @moduledoc """
  This module defines the base command for IRC client tests.
  """

  use ExUnit.CaseTemplate

  @spec new_connection(:tcp | :ssl) :: {:ok, :inet.socket()}
  def new_connection(:tcp) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", 6667, [:binary, :inet, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  def new_connection(:ssl) do
    {:ok, socket} = :ssl.connect(~c"127.0.0.1", 6697, [:binary, :inet, active: false, verify: :verify_none])
    on_exit(fn -> :ssl.close(socket) end)
    socket
  end
end
