defmodule ElixIRCd.Commands.Join do
  @moduledoc """
  This module defines the JOIN command.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

  require Logger

  @behaviour ElixIRCd.Commands.Behavior

  @type channel_states :: :created | :existing

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
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
    with {:ok, channel, channel_state} <- get_or_create_channel(channel_name),
         {:ok, user_channel} <- create_user_channel(user, channel, channel_state) do
      join_channel(user, channel, user_channel)
    else
      {:error, %Changeset{errors: errors}} ->
        error_message = Enum.map_join(errors, ", ", fn {_, {message, _}} -> message end)

        MessageBuilder.server_message(
          :rpl_cannotjoinchannel,
          [user.nick, channel_name],
          "Cannot join channel: #{error_message}"
        )
        |> Messaging.send_message(user)
    end

    :ok
  end

  @spec get_or_create_channel(String.t()) ::
          {:ok, Schemas.Channel.t(), channel_states} | {:error, Changeset.t()}
  defp get_or_create_channel(channel_name) do
    with {:error, _} <- Contexts.Channel.get_by_name(channel_name),
         {:ok, channel} <- Contexts.Channel.create(%{name: channel_name, topic: "Welcome to #{channel_name}."}) do
      {:ok, channel, :created}
    else
      {:ok, channel} -> {:ok, channel, :existing}
      error -> error
    end
  end

  @spec create_user_channel(Schemas.User.t(), Schemas.Channel.t(), channel_states) ::
          {:ok, Schemas.UserChannel.t()} | {:error, Changeset.t()}
  defp create_user_channel(user, channel, channel_state) do
    Contexts.UserChannel.create(%{
      user_socket: user.socket,
      channel_name: channel.name,
      modes: determine_user_channel_modes(channel_state)
    })
  end

  @spec determine_user_channel_modes(channel_states) :: [tuple()]
  defp determine_user_channel_modes(:created), do: [{:operator, true}]
  defp determine_user_channel_modes(_), do: []

  @spec join_channel(Schemas.User.t(), Schemas.Channel.t(), Schemas.UserChannel.t()) :: :ok
  defp join_channel(user, channel, user_channel) do
    channel_users = Contexts.UserChannel.get_by_channel(channel) |> Enum.map(& &1.user)

    MessageBuilder.user_message(user.identity, "JOIN", [channel.name])
    |> Messaging.send_message(channel_users)

    if Enum.find(user_channel.modes, fn {mode, _} -> mode == :operator end) do
      MessageBuilder.server_message("MODE", [channel.name, "+o", user.nick])
      |> Messaging.send_message(channel_users)
    end

    channel_user_nicks = channel_users |> Enum.map_join(" ", fn user -> user.nick end)

    messages = [
      {:rpl_topic, [user.nick, channel.name], channel.topic},
      {:rpl_namreply, ["=", user.nick, channel.name], channel_user_nicks},
      {:rpl_endofnames, [user.nick, channel.name], "End of NAMES list."}
    ]

    messages
    |> Enum.map(fn {command, params, body} -> MessageBuilder.server_message(command, params, body) end)
    |> Messaging.send_messages(user)

    :ok
  end
end
