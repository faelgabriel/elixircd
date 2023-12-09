defmodule ElixIRCd.Commands.Join do
  @moduledoc """
  This module defines the JOIN command.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder

  require Logger

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(%{identity: nil} = user, %{command: "JOIN"}) do
    MessageBuilder.server_message(:rpl_notregistered, ["*"], "You have not registered")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: [channel_names]}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.each(&handle_channel(user, &1))
  end

  @impl true
  def handle(user, %{command: "JOIN"}) do
    MessageBuilder.server_message(:rpl_needmoreparams, [user.nick, "JOIN"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @spec handle_channel(Schemas.User.t(), String.t()) :: :ok
  defp handle_channel(user, channel_name) do
    case get_or_create_channel(channel_name) do
      %Schemas.Channel{} = channel ->
        join_channel(user, channel)

      {:error, %Changeset{errors: errors}} ->
        error_message = Enum.map_join(errors, ", ", fn {_, {message, _}} -> message end)

        MessageBuilder.server_message(
          :rpl_cannotjoinchannel,
          [user.nick, channel_name],
          "Cannot join channel: #{error_message}"
        )
        |> Messaging.send_message(user)
    end
  end

  @spec get_or_create_channel(String.t()) :: Schemas.Channel.t() | {:error, Changeset.t()}
  defp get_or_create_channel(channel_name) do
    with {:error, _} <- Contexts.Channel.get_by_name(channel_name),
         {:ok, channel} <- Contexts.Channel.create(%{name: channel_name}) do
      channel
    else
      {:ok, channel} -> channel
      error -> error
    end
  end

  @spec join_channel(Schemas.User.t(), Schemas.Channel.t()) :: :ok
  defp join_channel(user, channel) do
    with {:ok, _user_channel} <- Contexts.UserChannel.create(%{user_socket: user.socket, channel_name: channel.name}) do
      channel = channel |> Repo.preload(user_channels: :user)
      channel_users = channel.user_channels |> Enum.map(& &1.user)

      MessageBuilder.user_message(user.identity, "JOIN", [channel.name])
      |> Messaging.send_message(channel_users)

      channel_user_nicks = channel_users |> Enum.map_join(" ", fn user -> user.nick end)

      messages = [
        {:rpl_topic, [user.nick, channel.name], "Channel topic here"},
        {:rpl_namreply, ["=", user.nick, channel.name], channel_user_nicks},
        {:rpl_endofnames, [user.nick, channel.name], "End of NAMES list."}
      ]

      messages
      |> Enum.map(fn {command, params, body} -> MessageBuilder.server_message(command, params, body) end)
      |> Messaging.send_messages(user)

      :ok
    end
  end
end
