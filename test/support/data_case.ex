defmodule ElixIRCd.DataCase do
  @moduledoc """
  This module defines the base test case for data tests.
  """

  # coveralls-ignore-start

  use ExUnit.CaseTemplate

  import ElixIRCd.Utils.Mnesia, only: [all_tables: 0]
  import ExUnit.CaptureLog

  alias ElixIRCd.Tables.User

  setup tags do
    unless tags[:async] do
      # Cleans up the Memento tables and kills all the users' processes and sockets opened in the tests.
      Memento.transaction!(fn ->
        Memento.Query.all(User)
        |> Enum.each(fn user ->
          if Process.alive?(user.pid), do: capture_log(fn -> Process.exit(user.pid, :kill) end)
        end)
      end)

      Enum.map(all_tables(), &Memento.Table.clear/1)
      |> Enum.each(fn
        :ok -> :ok
        {:error, reason} -> raise "Failed to clear table: #{inspect(reason)}"
      end)

      Memento.wait(all_tables())
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
