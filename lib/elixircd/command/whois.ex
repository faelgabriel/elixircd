defmodule ElixIRCd.Command.Whois do
  @moduledoc """
  This module defines the WHOIS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @command "WHOIS"

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: @command}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, @command],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: target_nicks}) when target_nicks != [] do
    target_nicks
    |> Enum.each(fn target_nick ->
      target_user =
        case Users.get_by_nick(target_nick) do
          {:ok, target_user} -> target_user
          {:error, _} -> nil
        end

      whois_message(user, target_nick, target_user)
    end)
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(User.t(), String.t(), User.t()) :: :ok
  def whois_message(user, target_nick, nil) do
    [
      Message.build(%{
        prefix: :server,
        command: :err_nosuchnick,
        params: [user.nick, target_nick],
        trailing: "No such nick"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_endofwhois,
        params: [user.nick, target_nick],
        trailing: "End of /WHOIS list."
      })
    ]
    |> Messaging.broadcast(user)
  end

  def whois_message(user, _target_nick, target_user) do
    target_user_channel_names =
      UserChannels.get_by_user_port(target_user.port)
      |> Enum.map(& &1.channel_name)

    [
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisuser,
        params: [user.nick, target_user.nick, target_user.username, target_user.hostname, "*"],
        trailing: target_user.realname
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_whoischannels,
        params: [user.nick, target_user.nick],
        trailing: target_user_channel_names |> Enum.join(" ")
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisserver,
        params: [user.nick, target_user.nick, "ElixIRCd", "0.1.0"],
        trailing: "Elixir IRC daemon"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisidle,
        params: [user.nick, target_user.nick, "0"],
        trailing: "seconds idle, signon time"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_endofwhois,
        params: [user.nick, target_user.nick],
        trailing: "End of /WHOIS list."
      })
    ]
    |> Messaging.broadcast(user)
  end
end
