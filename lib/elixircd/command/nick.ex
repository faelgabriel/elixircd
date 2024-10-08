defmodule ElixIRCd.Command.Nick do
  @moduledoc """
  This module defines the NICK command.
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Helper, only: [get_user_mask: 1, get_user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "NICK", params: [], trailing: nil}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [get_user_reply(user), "NICK"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NICK", params: [], trailing: nick}) do
    handle(user, %Message{command: "NICK", params: [nick]})
  end

  @impl true
  def handle(user, %{command: "NICK", params: [nick | _rest]}) do
    # Issue: nick needs to be case unsensitive
    with :ok <- validate_nick(nick),
         {:nick_in_use?, false} <- {:nick_in_use?, nick_in_use?(nick)} do
      change_nick(user, nick)
    else
      {:error, invalid_nick_error} ->
        user_reply = get_user_reply(user)

        Message.build(%{
          prefix: :server,
          command: :err_erroneusnickname,
          params: [user_reply, nick],
          trailing: "Nickname is unavailable: #{invalid_nick_error}"
        })
        |> Messaging.broadcast(user)

      {:nick_in_use?, true} ->
        user_reply = get_user_reply(user)

        Message.build(%{
          prefix: :server,
          command: :err_nicknameinuse,
          params: [user_reply, nick],
          trailing: "Nickname is already in use"
        })
        |> Messaging.broadcast(user)
    end
  end

  @spec change_nick(User.t(), String.t()) :: :ok
  defp change_nick(%{registered: false} = user, nick) do
    updated_user = Users.update(user, %{nick: nick})
    Handshake.handle(updated_user)
  end

  defp change_nick(user, nick) do
    old_user_mask = get_user_mask(user)
    updated_user = Users.update(user, %{nick: nick})

    all_channel_users =
      UserChannels.get_by_user_port(user.port)
      |> Enum.map(& &1.channel_name)
      |> UserChannels.get_by_channel_names()
      |> Enum.reject(fn user_channel -> user_channel.user_port == updated_user.port end)
      |> Enum.group_by(& &1.user_port)
      |> Enum.map(fn {_key, user_channels} -> hd(user_channels) end)

    Message.build(%{prefix: old_user_mask, command: "NICK", params: [nick]})
    |> Messaging.broadcast([updated_user | all_channel_users])
  end

  @spec nick_in_use?(String.t()) :: boolean()
  defp nick_in_use?(nick) do
    case Users.get_by_nick(nick) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @spec validate_nick(String.t()) :: :ok | {:error, String.t()}
  defp validate_nick(nick) do
    max_nick_length = 30
    nick_pattern = ~r/\A[a-zA-Z\`|\^_{}\[\]\\][a-zA-Z\d\`|\^_\-{}\[\]\\]*\z/

    cond do
      String.length(nick) > max_nick_length -> {:error, "Nickname too long"}
      !Regex.match?(nick_pattern, nick) -> {:error, "Illegal characters"}
      true -> :ok
    end
  end
end
