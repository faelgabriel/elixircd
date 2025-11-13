defmodule ElixIRCd.Services.Nickserv.Regain do
  @moduledoc """
  This module defines the NickServ REGAIN command.

  REGAIN allows users to disconnect sessions using their nickname and immediately take it.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["REGAIN", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} -> handle_registered_nick(user, registered_nick, password)
      {:error, :registered_nick_not_found} -> notify(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end
  end

  def handle(user, ["REGAIN" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02REGAIN\x02.",
      "Syntax: \x02REGAIN <nickname> <password>\x02"
    ])
  end

  @spec handle_registered_nick(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp handle_registered_nick(user, registered_nick, password) do
    if user.identified_as == registered_nick.nickname do
      regain_nickname(user, registered_nick)
    else
      verify_password_for_regain(user, registered_nick, password)
    end
  end

  @spec verify_password_for_regain(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp verify_password_for_regain(user, registered_nick, password) do
    if is_nil(password) do
      notify(user, [
        "Insufficient parameters for \x02REGAIN\x02.",
        "Syntax: \x02REGAIN <nickname> <password>\x02"
      ])
    else
      if Argon2.verify_pass(password, registered_nick.password_hash) do
        regain_nickname(user, registered_nick)
      else
        notify(user, "Invalid password for \x02#{registered_nick.nickname}\x02.")
      end
    end
  end

  @spec regain_nickname(User.t(), RegisteredNick.t()) :: :ok
  defp regain_nickname(user, registered_nick) do
    case Users.get_by_nick(registered_nick.nickname) do
      {:ok, target_user} ->
        if user.pid == target_user.pid do
          notify(user, "You cannot regain your own session.")
          :ok
        else
          ghost_message = "Killed (#{user.nick} (REGAIN command used))"
          send(target_user.pid, {:disconnect, ghost_message})

          reserve_nickname(registered_nick)
          handle_immediate_nick_change(user, registered_nick)

          notify(user, "Nick \x02#{registered_nick.nickname}\x02 has been regained.")

          :ok
        end

      {:error, :user_not_found} ->
        handle_immediate_nick_change(user, registered_nick)

        notify(user, "You have regained the nickname \x02#{registered_nick.nickname}\x02.")
    end
  end

  @spec handle_immediate_nick_change(User.t(), RegisteredNick.t()) :: :ok
  defp handle_immediate_nick_change(user, registered_nick) do
    updated_user = Users.update(user, %{nick: registered_nick.nickname})

    all_channel_user_pids =
      UserChannels.get_by_user_pid(user.pid)
      |> Enum.map(& &1.channel_name_key)
      |> UserChannels.get_by_channel_names()
      |> Enum.reject(fn user_channel -> user_channel.user_pid == updated_user.pid end)
      |> Enum.group_by(& &1.user_pid)
      |> Enum.map(fn {_key, user_channels} -> hd(user_channels) end)
      |> Enum.map(& &1.user_pid)

    all_users = Users.get_by_pids(all_channel_user_pids)

    %Message{command: "NICK", params: [registered_nick.nickname]}
    |> Dispatcher.broadcast(user, [updated_user | all_users])

    :ok
  end

  @spec reserve_nickname(RegisteredNick.t()) :: RegisteredNick.t()
  defp reserve_nickname(registered_nick) do
    reservation_duration = Application.get_env(:elixircd, :services)[:nickserv][:regain_reservation_duration] || 60

    reserved_until = DateTime.add(DateTime.utc_now(), reservation_duration, :second)
    RegisteredNicks.update(registered_nick, %{reserved_until: reserved_until})
  end
end
