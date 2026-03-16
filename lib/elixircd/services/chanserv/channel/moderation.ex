defmodule ElixIRCd.Services.Chanserv.Channel.Moderation do
  @moduledoc false

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @doc false
  @spec ensure_peace(RegisteredChannel.t(), User.t(), [User.t()], %{optional(String.t()) => String.t()}) ::
          :ok | {:error, :peace_denied}
  def ensure_peace(registered_channel, user, targets, access_entries) do
    if Enum.any?(targets, &peace_denied?(registered_channel, user, &1, access_entries)) do
      {:error, :peace_denied}
    else
      :ok
    end
  end

  @doc false
  @spec kick_targets(Channel.t(), [User.t()], String.t() | nil) :: non_neg_integer()
  def kick_targets(channel, targets, reason) do
    reason = reason || "Requested by ChanServ"

    Enum.reduce(targets, 0, fn target, kicked_count ->
      case UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name) do
        {:ok, target_user_channel} ->
          remaining_user_channels = UserChannels.get_by_channel_name(channel.name)
          UserChannels.delete(target_user_channel)

          remaining_users =
            remaining_user_channels
            |> Enum.map(& &1.user_pid)
            |> Enum.uniq()
            |> then(&Users.get_by_pids/1)

          %Message{command: "KICK", params: [channel.name, target.nick], trailing: reason}
          |> Dispatcher.broadcast(:chanserv, remaining_users)

          cleanup_empty_channel(channel)
          kicked_count + 1

        {:error, :user_channel_not_found} ->
          kicked_count
      end
    end)
  end

  @spec peace_denied?(RegisteredChannel.t(), User.t(), User.t(), %{optional(String.t()) => String.t()}) :: boolean()
  defp peace_denied?(registered_channel, user, target_user, access_entries) do
    registered_channel.settings.peace and
      not is_nil(target_user.identified_as) and
      user.identified_as != target_user.identified_as and
      not Flags.founder?(registered_channel, user.identified_as) and
      Flags.access_rank(registered_channel, target_user.identified_as, access_entries) >=
        Flags.access_rank(registered_channel, user.identified_as, access_entries)
  end

  @spec cleanup_empty_channel(Channel.t()) :: :ok
  defp cleanup_empty_channel(channel) do
    if UserChannels.get_by_channel_name(channel.name) == [] do
      ChannelInvites.delete_by_channel_name(channel.name)
      Channels.delete(channel)
    end

    :ok
  end
end
