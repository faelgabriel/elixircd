defmodule ElixIRCd.Commands.Quit do
  @moduledoc """
  This module defines the QUIT command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Handlers.MessageHandler
  alias ElixIRCd.Handlers.ServerHandler
  alias ElixIRCd.Repo
  alias ElixIRCd.Schemas

  @behaviour ElixIRCd.Behaviors.Command

  @impl true
  def handle(user, %{command: "QUIT", body: quit_message}) do
    user_channels = Contexts.UserChannel.get_by_user(user)

    Enum.each(user_channels, fn %Schemas.UserChannel{} = user_channel ->
      # Broadcast QUIT message to all users in the channel
      channel = user_channel.channel |> Repo.preload(user_channels: :user)
      channel_users = channel.user_channels |> Enum.map(& &1.user)
      MessageHandler.broadcast(channel_users, "#{user.identity} QUIT :#{quit_message}")
    end)

    # Delete the user and all associated user channels
    Contexts.User.delete(user)

    ServerHandler.close_connection(user)

    :ok
  end
end
