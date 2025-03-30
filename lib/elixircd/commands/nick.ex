defmodule ElixIRCd.Commands.Nick do
  @moduledoc """
  This module defines the NICK command.
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "NICK", params: [], trailing: nil}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply(user), "NICK"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NICK", params: [], trailing: nick}) do
    handle(user, %Message{command: "NICK", params: [nick]})
  end

  @impl true
  def handle(user, %{command: "NICK", params: [nick | _rest]}) do
    # Issue: nick needs to be case unsensitive
    with :ok <- validate_nick(nick),
         :ok <- check_reserved_nick(user, nick),
         {:nick_in_use?, false} <- {:nick_in_use?, nick_in_use?(nick)} do
      change_nick(user, nick)
    else
      {:error, :nick_reserved} ->
        Message.build(%{
          prefix: :server,
          command: :err_nicknameinuse,
          params: [user_reply(user), nick],
          trailing: "This nickname is reserved. Please identify to NickServ first."
        })
        |> Dispatcher.broadcast(user)

      {:nick_in_use?, true} ->
        Message.build(%{
          prefix: :server,
          command: :err_nicknameinuse,
          params: [user_reply(user), nick],
          trailing: "Nickname is already in use"
        })
        |> Dispatcher.broadcast(user)

      {:error, invalid_nick_error} ->
        Message.build(%{
          prefix: :server,
          command: :err_erroneusnickname,
          params: [user_reply(user), nick],
          trailing: "Nickname is unavailable: #{invalid_nick_error}"
        })
        |> Dispatcher.broadcast(user)
    end
  end

  @spec check_reserved_nick(User.t(), String.t()) :: :ok | {:error, :nick_reserved}
  defp check_reserved_nick(user, nick) do
    case RegisteredNicks.get_by_nickname(nick) do
      {:ok, registered_nick} ->
        if reserved?(registered_nick) do
          # Nickname is reserved, only the owner can use it
          if user.identified_as == registered_nick.nickname do
            :ok
          else
            {:error, :nick_reserved}
          end
        else
          :ok
        end

      {:error, _} ->
        # Nickname is not registered, so not reserved
        :ok
    end
  end

  @spec change_nick(User.t(), String.t()) :: :ok
  defp change_nick(%{registered: false} = user, nick) do
    updated_user = Users.update(user, %{nick: nick})
    Handshake.handle(updated_user)
  end

  defp change_nick(user, nick) do
    old_user_mask = user_mask(user)
    updated_user = Users.update(user, %{nick: nick})

    all_channel_users =
      UserChannels.get_by_user_pid(user.pid)
      |> Enum.map(& &1.channel_name)
      |> UserChannels.get_by_channel_names()
      |> Enum.reject(fn user_channel -> user_channel.user_pid == updated_user.pid end)
      |> Enum.group_by(& &1.user_pid)
      |> Enum.map(fn {_key, user_channels} -> hd(user_channels) end)

    Message.build(%{prefix: old_user_mask, command: "NICK", params: [nick]})
    |> Dispatcher.broadcast([updated_user | all_channel_users])
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

  @spec reserved?(ElixIRCd.Tables.RegisteredNick.t()) :: boolean()
  defp reserved?(registered_nick) do
    case registered_nick.reserved_until do
      nil -> false
      reserved_until -> DateTime.compare(reserved_until, DateTime.utc_now()) == :gt
    end
  end
end
