defmodule ElixIRCd.Command.Join do
  @moduledoc """
  This module defines the JOIN command.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  require Logger

  @behaviour ElixIRCd.Command

  @type channel_states :: :created | :existing

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "JOIN"}) do
    Message.new(%{source: :server, command: :err_notregistered, params: ["*"], body: "You have not registered"})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: []}) do
    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user.nick, "JOIN"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: [channel_names]}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.each(&handle_channel(user, &1))
  end

  @spec handle_channel(Schemas.User.t(), String.t()) :: :ok
  defp handle_channel(user, channel_name) do
    with {:ok, channel, channel_state} <- get_or_create_channel(channel_name),
         {:ok, user_channel} <- create_user_channel(user, channel, channel_state) do
      join_channel(user, channel, user_channel)
    else
      {:error, %Changeset{errors: errors}} ->
        error_message = Enum.map_join(errors, ", ", fn {_, {message, _}} -> message end)

        Message.new(%{
          source: :server,
          command: :err_cannotjoinchannel,
          params: [user.nick, channel_name],
          body: "Cannot join channel: #{error_message}"
        })
        |> Server.send_message(user)
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

    Message.new(%{
      source: user.identity,
      command: "JOIN",
      params: [channel.name]
    })
    |> Server.send_message(channel_users)

    if Enum.find(user_channel.modes, fn {mode, _} -> mode == :operator end) do
      Message.new(%{
        source: :server,
        command: "MODE",
        params: [channel.name, "+o", user.nick]
      })
      |> Server.send_message(channel_users)
    end

    channel_user_nicks =
      channel_users
      |> Enum.sort(fn user1, user2 -> user1.created_at >= user2.created_at end)
      |> Enum.map_join(" ", fn user -> user.nick end)

    [
      Message.new(%{source: :server, command: :rpl_topic, params: [user.nick, channel.name], body: channel.topic}),
      Message.new(%{
        source: :server,
        command: :rpl_namreply,
        params: ["=", user.nick, channel.name],
        body: channel_user_nicks
      }),
      Message.new(%{
        source: :server,
        command: :rpl_endofnames,
        params: [user.nick, channel.name],
        body: "End of NAMES list."
      })
    ]
    |> Server.send_messages(user)

    :ok
  end
end
