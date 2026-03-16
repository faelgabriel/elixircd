defmodule ElixIRCd.Services.Chanserv.Invite do
  @moduledoc """
  This module defines the ChanServ INVITE command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "INVITE"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name]) do
    handle(user, [@command_name, channel_name, user.nick])
  end

  def handle(user, [@command_name, channel_name, target_nick | _rest]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, channel} <- ChannelContext.get_online_channel(registered_channel.name),
         {:ok, target_user} <- Users.get_by_nick(target_nick),
         {:error, :user_channel_not_found} <-
           UserChannels.get_by_user_pid_and_channel_name(target_user.pid, channel.name) do
      maybe_add_invite(channel, target_user, user)

      %Message{command: "INVITE", params: [target_user.nick, channel.name]}
      |> Dispatcher.broadcast(:chanserv, target_user)

      notify(user, "\x02#{target_user.nick}\x02 has been invited to \x02#{channel.name}\x02.")
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")

      {:error, :user_not_found} ->
        notify(user, "The nickname \x02#{target_nick}\x02 is not online.")

      {:ok, _user_channel} ->
        notify(user, "\x02#{target_nick}\x02 is already on \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, "Syntax: \x02INVITE <channel> [nickname]\x02")
  end

  @spec maybe_add_invite(Channel.t(), User.t(), User.t()) :: :ok
  defp maybe_add_invite(channel, target_user, user) do
    if "i" in channel.modes do
      ChannelInvites.create(%{user_pid: target_user.pid, channel_name_key: channel.name_key, setter: user_mask(user)})
    end

    :ok
  end
end
