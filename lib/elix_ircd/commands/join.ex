defmodule ElixIRCd.Commands.Join do
  @moduledoc """
  This module defines the JOIN command.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas

  require Logger

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "JOIN", params: [channel_names]}) when user.identity != nil do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.each(&handle_channel(user, &1))
  end

  @impl true
  def handle(user, %{command: "JOIN"}) when user.identity != nil do
    Messaging.message_not_enough_params(user, "JOIN")
  end

  @impl true
  def handle(user, %{command: "JOIN"}) do
    Messaging.message_not_registered(user)
  end

  @spec handle_channel(Schemas.User.t(), String.t()) :: :ok
  defp handle_channel(user, channel_name) do
    case get_or_create_channel(channel_name) do
      %Schemas.Channel{} = channel ->
        join_channel(user, channel)

      {:error, %Changeset{errors: errors}} ->
        error_message = Enum.map_join(errors, ", ", fn {_, {message, _}} -> message end)

        Messaging.send_message(
          user,
          :server,
          "448 #{user.nick} #{channel_name} :Cannot join channel: #{error_message}"
        )
    end
  end

  @spec get_or_create_channel(String.t()) :: Schemas.Channel.t() | {:error, Changeset.t()}
  defp get_or_create_channel(channel_name) do
    with nil <- Contexts.Channel.get_by_name(channel_name),
         {:ok, channel} <- Contexts.Channel.create(%{name: channel_name}) do
      channel
    end
  end

  @spec join_channel(Schemas.User.t(), Schemas.Channel.t()) :: :ok
  defp join_channel(user, channel) do
    with {:ok, _user_channel} <- Contexts.UserChannel.create(%{user_socket: user.socket, channel_name: channel.name}) do
      channel = channel |> Repo.preload(user_channels: :user)
      channel_users = channel.user_channels |> Enum.map(& &1.user)

      Messaging.broadcast(channel_users, ":#{user.identity} JOIN #{channel.name}")

      Messaging.send_message(
        user,
        :server,
        "332 #{user.nick} #{channel.name} :this is a topic and it is a grand topic"
      )

      names = channel_users |> Enum.map_join(" ", fn user -> user.nick end)

      Messaging.send_message(user, :server, "353 #{user.nick} = #{channel.name} :#{names}")
      Messaging.send_message(user, :server, "366 #{user.nick} #{channel.name} :End of /NAMES list.")
      :ok
    end
  end
end
