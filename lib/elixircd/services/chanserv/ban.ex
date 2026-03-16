defmodule ElixIRCd.Services.Chanserv.Ban do
  @moduledoc """
  This module defines the ChanServ BAN command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  import ElixIRCd.Utils.Protocol,
    only: [match_user_mask?: 2, normalize_mask: 1, user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Services.Chanserv.Channel.Moderation
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "BAN"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name, target | _rest]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, channel, _user_channels, channel_users} <-
           ChannelContext.get_online_channel_state(registered_channel.name),
         ban_mask <- resolve_ban_mask(target),
         matched_targets <- Enum.filter(channel_users, &match_user_mask?(&1, ban_mask)),
         :ok <- Moderation.ensure_peace(registered_channel, user, matched_targets, access_entries),
         :ok <- create_ban(channel, channel_users, ban_mask, user) do
      notify(user, "Ban \x02#{ban_mask}\x02 has been added to \x02#{channel.name}\x02.")
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")

      {:error, :peace_denied} ->
        notify(
          user,
          "Channel \x02#{channel_name}\x02 has \x02PEACE\x02 enabled; you cannot ban a matching protected target."
        )

      {:error, :already_banned, ban_mask} ->
        notify(user, "Ban \x02#{ban_mask}\x02 is already set on \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, [
      "Insufficient parameters for \x02BAN\x02.",
      "Syntax: \x02BAN <channel> <nickname|mask>\x02"
    ])
  end

  @spec resolve_ban_mask(String.t()) :: String.t()
  defp resolve_ban_mask(target) do
    case Users.get_by_nick(target) do
      {:ok, target_user} -> normalize_mask(user_mask(target_user))
      {:error, :user_not_found} -> normalize_mask(target)
    end
  end

  @spec create_ban(Channel.t(), [User.t()], String.t(), User.t()) :: :ok | {:error, :already_banned, String.t()}
  defp create_ban(channel, channel_users, ban_mask, user) do
    case ChannelBans.get_by_channel_name_key_and_mask(channel.name_key, ban_mask) do
      {:ok, _channel_ban} ->
        {:error, :already_banned, ban_mask}

      {:error, :channel_ban_not_found} ->
        ChannelBans.create(%{channel_name_key: channel.name_key, mask: ban_mask, setter: user_mask(user)})

        %Message{command: "MODE", params: [channel.name, "+b", ban_mask]}
        |> Dispatcher.broadcast(:chanserv, channel_users)

        :ok
    end
  end
end
