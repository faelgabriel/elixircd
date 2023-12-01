defmodule ElixIRCd.Commands.Whois do
  @moduledoc """
  This module defines the WHOIS command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "WHOIS", params: [target_nick]}) when user.identity != nil do
    case Contexts.User.get_by_nick(target_nick) do
      %Schemas.User{} = target_user ->
        whois_message(user, target_user)

      nil ->
        MessageBuilder.server_message(:rpl_nouser, [user.nick, target_nick], "No such nick")
        |> Messaging.send_message(user)
    end

    :ok
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(Schemas.User.t(), Schemas.User.t()) :: :ok
  def whois_message(user, target_user) do
    target_user = target_user |> Repo.preload(user_channels: :channel)
    target_user_channel_names = target_user.user_channels |> Enum.map(& &1.channel.name)

    messages = [
      {:rpl_whoisuser, [user.nick, target_user.nick, target_user.username, target_user.hostname, "*"],
       target_user.realname},
      {:rpl_whoisserver, [user.nick, target_user.nick, "ElixIRCd", "0.1.0"], "Elixir IRC daemon"},
      {:rpl_whoisidle, [user.nick, target_user.nick, "0"], "seconds idle, signon time"},
      {:rpl_whoischannels, [user.nick, target_user.nick], target_user_channel_names |> Enum.join(" ")},
      {:rpl_endofwhois, [user.nick, target_user.nick], "End of /WHOIS list."}
    ]

    messages
    |> Enum.map(fn {command, params, body} -> MessageBuilder.server_message(command, params, body) end)
    |> Messaging.send_messages(user)

    :ok
  end
end
