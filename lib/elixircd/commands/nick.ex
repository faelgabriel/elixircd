defmodule ElixIRCd.Commands.Nick do
  @moduledoc """
  This module defines the NICK command.

  NICK changes or sets the user's nickname.
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

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
      command: :err_needmoreparams,
      params: [user_reply(user), "NICK"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "NICK", params: [], trailing: input_nick}) do
    handle(user, %Message{command: "NICK", params: [input_nick]})
  end

  @impl true
  def handle(user, %{command: "NICK", params: [input_nick | _rest]}) do
    with :ok <- validate_nick(input_nick),
         :ok <- check_reserved_nick(user, input_nick),
         :ok <- check_nick_in_use(input_nick) do
      change_nick(user, input_nick)
    else
      {:error, :nick_reserved} ->
        Message.build(%{
          command: :err_nicknameinuse,
          params: [user_reply(user), input_nick],
          trailing: "This nickname is reserved. Please identify to NickServ first."
        })
        |> Dispatcher.broadcast(:server, user)

      {:error, :nick_in_use} ->
        Message.build(%{
          command: :err_nicknameinuse,
          params: [user_reply(user), input_nick],
          trailing: "Nickname is already in use"
        })
        |> Dispatcher.broadcast(:server, user)

      {:error, invalid_nick_error} ->
        Message.build(%{
          command: :err_erroneusnickname,
          params: [user_reply(user), input_nick],
          trailing: "Nickname is unavailable: #{invalid_nick_error}"
        })
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec check_reserved_nick(User.t(), String.t()) :: :ok | {:error, :nick_reserved}
  defp check_reserved_nick(user, input_nick) do
    with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(input_nick),
         {:reserved, true} <- {:reserved, reserved?(registered_nick)},
         {:identified, false} <- {:identified, user.identified_as == registered_nick.nickname} do
      {:error, :nick_reserved}
    else
      {:error, :registered_nick_not_found} -> :ok
      {:reserved, false} -> :ok
      {:identified, true} -> :ok
    end
  end

  @spec change_nick(User.t(), String.t()) :: :ok
  defp change_nick(%{registered: false} = user, input_nick) do
    updated_user = Users.update(user, %{nick: input_nick})
    Handshake.handle(updated_user)
  end

  defp change_nick(user, input_nick) do
    updated_user = Users.update(user, %{nick: input_nick})

    all_channel_users =
      UserChannels.get_by_user_pid(user.pid)
      |> Enum.map(& &1.channel_name_key)
      |> UserChannels.get_by_channel_names()
      |> Enum.reject(fn user_channel -> user_channel.user_pid == updated_user.pid end)
      |> Enum.group_by(& &1.user_pid)
      |> Enum.map(fn {_key, user_channels} -> hd(user_channels) end)

    Message.build(%{command: "NICK", params: [input_nick]})
    |> Dispatcher.broadcast(user, [updated_user | all_channel_users])
  end

  @spec check_nick_in_use(String.t()) :: :ok | {:error, :nick_in_use}
  defp check_nick_in_use(input_nick) do
    case Users.get_by_nick(input_nick) do
      {:ok, _user} -> {:error, :nick_in_use}
      {:error, :user_not_found} -> :ok
    end
  end

  @spec validate_nick(String.t()) :: :ok | {:error, String.t()}
  defp validate_nick(input_nick) do
    max_nick_length = Application.get_env(:elixircd, :user)[:max_nick_length]
    nick_pattern = ~r/\A[a-zA-Z\`|\^_{}\[\]\\][a-zA-Z\d\`|\^_\-{}\[\]\\]*\z/

    cond do
      String.length(input_nick) > max_nick_length ->
        {:error, "Nickname too long (maximum length: #{max_nick_length} characters)"}

      !Regex.match?(nick_pattern, input_nick) ->
        {:error, "Illegal characters"}

      true ->
        :ok
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
