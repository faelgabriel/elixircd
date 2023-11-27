defmodule ElixIRCd.Commands.Quit do
  @moduledoc """
  This module defines the QUIT command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Core.Server
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "QUIT", body: quit_message}) do
    user_channels = Contexts.UserChannel.get_by_user(user)

    Enum.each(user_channels, fn %Schemas.UserChannel{} = user_channel ->
      # Broadcast QUIT message to all users in the channel
      channel = user_channel.channel |> Repo.preload(user_channels: :user)
      channel_users = channel.user_channels |> Enum.map(& &1.user)
      Messaging.broadcast(channel_users, "#{user.identity} QUIT :#{quit_message}")
    end)

    # Delete the user and all associated user channels
    Contexts.User.delete(user)

    Server.close_connection(user)

    :ok
  end
end
