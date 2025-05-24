defmodule ElixIRCd.Commands.Away do
  @moduledoc """
  This module defines the AWAY command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "AWAY"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "AWAY", trailing: nil}) do
    updated_user = Users.update(user, %{away_message: nil})

    Message.build(%{
      prefix: :server,
      command: :rpl_unaway,
      params: [updated_user.nick],
      trailing: "You are no longer marked as being away"
    })
    |> Dispatcher.broadcast(updated_user)

    :ok
  end

  @impl true
  def handle(user, %{command: "AWAY", trailing: reason}) do
    max_away_length = Application.get_env(:elixircd, :user)[:max_away_message_length]

    if String.length(reason) > max_away_length do
      Message.build(%{
        prefix: :server,
        command: :err_inputtoolong,
        params: [user.nick],
        trailing: "Away message too long (maximum length: #{max_away_length} characters)"
      })
      |> Dispatcher.broadcast(user)
    else
      updated_user = Users.update(user, %{away_message: reason})

      Message.build(%{
        prefix: :server,
        command: :rpl_nowaway,
        params: [updated_user.nick],
        trailing: "You have been marked as being away"
      })
      |> Dispatcher.broadcast(updated_user)
    end

    :ok
  end
end
