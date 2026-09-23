defmodule ElixIRCd.Commands.Nick do
  @moduledoc """
  This module defines the NICK command.

  NICK changes or sets the user's nickname.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Nickserv, only: [belongs_to_account?: 2, sync_registered_mode: 1]
  import ElixIRCd.Utils.Protocol, only: [channel_operator?: 1, channel_voice?: 1, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Server.NickChange
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.Server.S2S.State
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "NICK", params: [], trailing: nil}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "NICK"], trailing: "Not enough parameters"}
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
         :ok <- NickEnforcement.authorize_nick(user, input_nick),
         :ok <- check_nick_in_use(user, input_nick),
         :ok <- check_channel_nick_change(user) do
      change_nick(user, input_nick)
    else
      {:error, :nick_reserved} ->
        %Message{
          command: :err_nicknameinuse,
          params: [user_reply(user), input_nick],
          trailing: "This nickname is reserved. Please identify to NickServ first."
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :nick_in_use} ->
        %Message{
          command: :err_nicknameinuse,
          params: [user_reply(user), input_nick],
          trailing: "Nickname is already in use"
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, {:nick_enforced, action}} ->
        NickEnforcement.reject_nick(user, input_nick, action)

      {:error, {:nick_change_blocked, channel_name}} ->
        %Message{
          command: "447",
          params: [user_reply(user), channel_name],
          trailing: "Cannot change nickname while on channel (+N)"
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, invalid_nick_error} ->
        %Message{
          command: :err_erroneusnickname,
          params: [user_reply(user), input_nick],
          trailing: "Nickname is unavailable: #{invalid_nick_error}"
        }
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec check_reserved_nick(User.t(), String.t()) :: :ok | {:error, :nick_reserved}
  defp check_reserved_nick(user, input_nick) do
    if State.fallback_nickname?(input_nick) and not State.fallback_nickname_for?(input_nick, user.uid) do
      {:error, :nick_reserved}
    else
      with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(input_nick),
           {:reserved, true} <- {:reserved, reserved?(registered_nick)},
           {:identified, false} <- {:identified, belongs_to_account?(registered_nick, user.identified_as)} do
        {:error, :nick_reserved}
      else
        {:error, :registered_nick_not_found} -> :ok
        {:reserved, false} -> :ok
        {:identified, true} -> :ok
      end
    end
  end

  @spec change_nick(User.t(), String.t()) :: :ok
  defp change_nick(%{nick: nick}, nick), do: :ok

  defp change_nick(%{registered: false} = user, input_nick) do
    NickEnforcement.cancel(user.pid)
    updated_user = Users.update(user, %{nick: input_nick})
    updated_user = sync_registered_mode(updated_user)
    NickEnforcement.schedule_enforcement(updated_user)
    Handshake.handle(updated_user)
  end

  defp change_nick(user, input_nick) do
    NickEnforcement.cancel(user.pid)
    updated_user = NickChange.change(user, input_nick)
    NickEnforcement.schedule_enforcement(updated_user)
    :ok
  end

  @spec check_nick_in_use(User.t(), String.t()) :: :ok | {:error, :nick_in_use}
  defp check_nick_in_use(user, input_nick) do
    case Users.get_by_nick(input_nick) do
      {:ok, target} -> if User.same_identity?(target, user), do: :ok, else: {:error, :nick_in_use}
      {:error, :user_not_found} -> :ok
    end
  end

  defp check_channel_nick_change(%{registered: false}), do: :ok

  defp check_channel_nick_change(user) do
    user.pid
    |> UserChannels.get_by_user_pid()
    |> Enum.find_value(:ok, fn membership ->
      with {:ok, channel} <- Channels.get_by_name(membership.channel_name_key),
           true <- :N in channel.modes,
           false <- channel_operator?(membership) or channel_voice?(membership) do
        {:error, {:nick_change_blocked, channel.name}}
      else
        _ -> false
      end
    end)
  end

  @spec validate_nick(String.t()) :: :ok | {:error, String.t()}
  defp validate_nick(input_nick) do
    max_nick_length = Application.fetch_env!(:elixircd, :user)[:max_nick_length]
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
