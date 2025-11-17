defmodule ElixIRCd.Commands.Away do
  @moduledoc """
  This module defines the AWAY command.

  AWAY sets or removes an away message for the user.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "AWAY"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "AWAY", trailing: nil}) do
    updated_user = Users.update(user, %{away_message: nil})

    %Message{command: :rpl_unaway, params: [updated_user.nick], trailing: "You are no longer marked as being away"}
    |> Dispatcher.broadcast(:server, updated_user)

    notify_away_change(updated_user)

    :ok
  end

  @impl true
  def handle(user, %{command: "AWAY", trailing: reason}) do
    max_away_length = Application.get_env(:elixircd, :user)[:max_away_message_length]

    if String.length(reason) > max_away_length do
      %Message{
        command: :err_inputtoolong,
        params: [user.nick],
        trailing: "Away message too long (maximum length: #{max_away_length} characters)"
      }
      |> Dispatcher.broadcast(:server, user)
    else
      updated_user = Users.update(user, %{away_message: reason})

      %Message{command: :rpl_nowaway, params: [updated_user.nick], trailing: "You have been marked as being away"}
      |> Dispatcher.broadcast(:server, updated_user)

      notify_away_change(updated_user)
    end

    :ok
  end

  @spec notify_away_change(User.t()) :: :ok
  defp notify_away_change(user) do
    away_notify_supported = Application.get_env(:elixircd, :capabilities)[:away_notify] || false

    if away_notify_supported do
      watchers = Users.get_in_shared_channels_with_capability(user, "AWAY-NOTIFY", false)

      if watchers != [] do
        %Message{command: "AWAY", params: [], trailing: user.away_message}
        |> Dispatcher.broadcast(user, watchers)
      end
    end

    :ok
  end
end
