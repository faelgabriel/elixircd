defmodule ElixIRCd.DataCase do
  @moduledoc """
  This module defines the base test case for data tests.
  """

  # coveralls-ignore-start

  use ExUnit.CaseTemplate

  import ExUnit.CaptureLog

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.Metric
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @tables [
    Channel,
    ChannelBan,
    ChannelInvite,
    HistoricalUser,
    Metric,
    User,
    UserChannel
  ]

  setup tags do
    unless tags[:async] do
      # Cleans up the Memento tables and kills all the users' processes and sockets opened in the tests.
      Memento.transaction!(fn ->
        Memento.Query.all(User)
        |> Enum.each(fn user ->
          if Process.alive?(user.pid), do: capture_log(fn -> Process.exit(user.pid, :kill) end)
          user.transport.close(user.socket)
        end)
      end)

      Enum.map(@tables, &Memento.Table.clear/1)
      |> Enum.each(fn
        :ok -> :ok
        {:error, reason} -> raise "Failed to clear table: #{inspect(reason)}"
      end)

      Memento.wait(@tables)
      |> case do
        :ok -> :ok
        {:timeout, tables} -> raise "Failed to wait for tables: #{inspect(tables)}"
        {:error, reason} -> raise "Failed to wait for tables: #{inspect(reason)}"
      end
    end

    :ok
  end

  # coveralls-ignore-stop
end
