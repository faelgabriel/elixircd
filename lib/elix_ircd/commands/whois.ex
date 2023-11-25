defmodule ElixIRCd.Commands.Whois do
  @moduledoc """
  This module defines the WHOIS command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Handlers.MessageHandler
  alias ElixIRCd.Repo
  alias ElixIRCd.Schemas

  @behaviour ElixIRCd.Behaviors.Command

  @impl true
  def handle(user, %{command: "WHOIS", params: [target_nick]}) when user.identity != nil do
    case Contexts.User.get_by_nick(target_nick) do
      %Schemas.User{} = target_user -> whois_message(user, target_user)
      nil -> MessageHandler.send_message(user, :server, "401 #{target_nick} :No such nick/channel")
    end

    :ok
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(Schemas.User.t(), Schemas.User.t()) :: :ok
  def whois_message(user, target_user) do
    MessageHandler.send_message(
      user,
      :server,
      "311 #{target_user.nick} #{target_user.nick} #{target_user.identity} * :#{target_user.realname}"
    )

    target_user = target_user |> Repo.preload(user_channels: :channel)
    target_user_channel_names = target_user.user_channels |> Enum.map(& &1.channel.name)

    MessageHandler.send_message(
      user,
      :server,
      "319 #{target_user.nick} #{target_user.nick} :#{target_user_channel_names |> Enum.join(" ")}"
    )

    MessageHandler.send_message(user, :server, "312 #{target_user.nick} ElixIRCd 0.1.0 :Elixir IRC daemon")

    MessageHandler.send_message(
      user,
      :server,
      "317 #{target_user.nick} #{target_user.nick} 0 :seconds idle, signon time"
    )

    MessageHandler.send_message(user, :server, "318 #{target_user.nick} #{target_user.nick} :End of /WHOIS list.")

    :ok
  end
end
