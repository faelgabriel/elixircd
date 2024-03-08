defmodule ElixIRCd.DataCase do
  @moduledoc """
  This module defines the base test case for data tests.
  """

  use ExUnit.CaseTemplate

  import ExUnit.CaptureLog

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @tables [
    Channel,
    ChannelBan,
    User,
    UserChannel
  ]

  setup tags do
    unless tags[:async] do
      on_exit(fn ->
        # Cleans up the Memento tables and kills all the users' processes and sockets opened in the tests.
        Memento.transaction!(fn ->
          Memento.Query.all(User)
          |> Enum.each(fn user ->
            if Process.alive?(user.pid), do: capture_log(fn -> Process.exit(user.pid, :kill) end)
            user.transport.close(user.socket)
          end)
        end)

        Enum.each(@tables, &Memento.Table.clear/1)
        Memento.wait(@tables)
      end)
    end

    :ok
  end
end
