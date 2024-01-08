defmodule ElixIRCd.Command.Whois do
  @moduledoc """
  This module defines the WHOIS command.
  """

  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  @behaviour ElixIRCd.Command.Behavior

  @command "WHOIS"

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: @command}) do
    Message.new(%{source: :server, command: :rpl_notregistered, params: ["*"], body: "You have not registered"})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: @command, params: target_nicks}) when target_nicks != [] do
    target_nicks
    |> Enum.each(fn target_nick ->
      target_user =
        case Contexts.User.get_by_nick(target_nick) do
          {:ok, target_user} -> target_user
          {:error, _} -> nil
        end

      whois_message(user, target_nick, target_user)
    end)

    :ok
  end

  @impl true
  def handle(user, %{command: @command}) do
    user_reply = Helper.get_user_reply(user)

    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user_reply, @command],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(Schemas.User.t(), String.t(), Schemas.User.t()) :: :ok
  def whois_message(user, target_nick, nil) do
    [
      Message.new(%{
        source: :server,
        command: :rpl_nouser,
        params: [user.nick, target_nick],
        body: "No such nick"
      }),
      Message.new(%{
        source: :server,
        command: :rpl_endofwhois,
        params: [user.nick, target_nick],
        body: "End of /WHOIS list."
      })
    ]
    |> Server.send_messages(user)

    :ok
  end

  def whois_message(user, _target_nick, target_user) do
    target_user_channel_names = Contexts.UserChannel.get_by_user(target_user) |> Enum.map(& &1.channel_name)

    [
      Message.new(%{
        source: :server,
        command: :rpl_whoisuser,
        params: [user.nick, target_user.nick, target_user.username, target_user.hostname, "*"],
        body: target_user.realname
      }),
      Message.new(%{
        source: :server,
        command: :rpl_whoischannels,
        params: [user.nick, target_user.nick],
        body: target_user_channel_names |> Enum.join(" ")
      }),
      Message.new(%{
        source: :server,
        command: :rpl_whoisserver,
        params: [user.nick, target_user.nick, "ElixIRCd", "0.1.0"],
        body: "Elixir IRC daemon"
      }),
      Message.new(%{
        source: :server,
        command: :rpl_whoisidle,
        params: [user.nick, target_user.nick, "0"],
        body: "seconds idle, signon time"
      }),
      Message.new(%{
        source: :server,
        command: :rpl_endofwhois,
        params: [user.nick, target_user.nick],
        body: "End of /WHOIS list."
      })
    ]
    |> Server.send_messages(user)

    :ok
  end
end
