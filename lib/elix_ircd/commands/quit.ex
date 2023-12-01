defmodule ElixIRCd.Commands.Quit do
  @moduledoc """
  This module defines the QUIT command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Core.Server
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "QUIT", body: quit_message}) do
    user_channels = Contexts.UserChannel.get_by_user(user)

    all_channel_users =
      Enum.reduce(user_channels, [], fn %Schemas.UserChannel{} = user_channel, acc ->
        channel = user_channel.channel |> Repo.preload(user_channels: :user)
        channel_users = channel.user_channels |> Enum.map(& &1.user)
        acc ++ channel_users
      end)
      |> Enum.uniq()
      |> Enum.reject(fn x -> x == user end)

    MessageBuilder.user_message(user.identity, "QUIT", [], quit_message)
    |> Messaging.send_message(all_channel_users)

    # Delete the user and all associated user channels
    Contexts.User.delete(user)

    Server.close_connection(user)

    :ok
  end
end
