defmodule ElixIRCd.WsServer do
  @moduledoc """
  Module for handling IRC connections over WebSocket (WS) and WebSocket Secure (WSS).
  """

  require Logger

  def init(state) do
    Logger.info("WebSocket connection initiated with state: #{inspect(state)}")
    {:ok, state}
  end

  def handle_in({msg, [opcode: :text]}, state) do
    Logger.debug("received txt #{inspect(msg)}, #{inspect(state)}")
    {:reply, :ok, {:text, msg}, state}
  end

  def handle_in({msg, [opcode: :binary]}, state) do
    Logger.debug("received bin #{inspect(msg)}, #{inspect(state)}")
    {:reply, :ok, {:text, msg}, state}
  end

  def terminate(reason, state) do
    Logger.info("WebSocket connection terminated with state: #{inspect(state)} due to: #{inspect(reason)}")
    :ok
  end
end
