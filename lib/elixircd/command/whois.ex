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
  def handle(%{identity: nil} = user, %{command: @command}) do
    Message.build(%{source: :server, command: :err_notregistered, params: ["*"], body: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user_reply, @command],
      body: "Not enough parameters"
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

    :ok
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(User.t(), String.t(), User.t()) :: :ok
  def whois_message(user, target_nick, nil) do
    [
      Message.build(%{
        source: :server,
        command: :err_nosuchnick,
        params: [user.nick, target_nick],
        body: "No such nick"
      }),
      Message.build(%{
        source: :server,
        command: :rpl_endofwhois,
        params: [user.nick, target_nick],
        body: "End of /WHOIS list."
      })
    ]
    |> Messaging.broadcast(user)

    :ok
  end

  def whois_message(user, _target_nick, target_user) do
    target_user_channel_names =
      UserChannels.get_by_user_port(target_user.port)
      |> Enum.map(& &1.channel_name)

    [
      Message.build(%{
        source: :server,
        command: :rpl_whoisuser,
        params: [user.nick, target_user.nick, target_user.username, target_user.hostname, "*"],
        body: target_user.realname
      }),
      Message.build(%{
        source: :server,
        command: :rpl_whoischannels,
        params: [user.nick, target_user.nick],
        body: target_user_channel_names |> Enum.join(" ")
      }),
      Message.build(%{
        source: :server,
        command: :rpl_whoisserver,
        params: [user.nick, target_user.nick, "ElixIRCd", "0.1.0"],
        body: "Elixir IRC daemon"
      }),
      Message.build(%{
        source: :server,
        command: :rpl_whoisidle,
        params: [user.nick, target_user.nick, "0"],
        body: "seconds idle, signon time"
      }),
      Message.build(%{
        source: :server,
        command: :rpl_endofwhois,
        params: [user.nick, target_user.nick],
        body: "End of /WHOIS list."
      })
    ]
    |> Messaging.broadcast(user)

    :ok
  end
end
