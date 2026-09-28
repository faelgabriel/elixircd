defmodule ElixIRCd.Services.Chanserv.Recover do
  @moduledoc "Allows the identified founder to regain operator control of a registered channel."

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Service
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags
  alias ElixIRCd.Utils.Chanserv.ModeLock

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, ["RECOVER" | _]),
    do: notify(user, "You must be identified with NickServ to use this command.")

  def handle(user, ["RECOVER", channel_name]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         true <- Flags.founder?(registered_channel, user.identified_as),
         {:ok, live_channel, memberships, users} <- ChannelContext.get_online_channel_state(registered_channel.name) do
      recover_channel(user, registered_channel, live_channel, memberships, users)
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      false ->
        notify(user, "Only the channel founder may use RECOVER.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use; join it to regain operator status.")
    end
  end

  def handle(user, ["RECOVER" | _]), do: notify(user, "Syntax: \x02RECOVER <channel>\x02")

  defp recover_channel(user, registered_channel, live_channel, memberships, users) do
    {live_channel, _changes} = ModeLock.reconcile_and_broadcast(live_channel, registered_channel)
    users_by_pid = Map.new(users, &{&1.pid, &1})

    Enum.each(memberships, fn membership ->
      case Map.fetch(users_by_pid, membership.user_pid) do
        {:ok, target} -> reconcile_operator(live_channel, membership, target, user, users)
        :error -> :ok
      end
    end)

    unless Enum.any?(memberships, &(&1.user_pid == user.pid)) do
      ChannelInvites.create(%{
        user_pid: user.pid,
        channel_name_key: live_channel.name_key,
        setter: Service.mask(:chanserv),
        bypass_ban: true
      })

      %Message{command: "INVITE", params: [user.nick, live_channel.name]}
      |> Dispatcher.broadcast(:chanserv, user)
    end

    notify(
      user,
      "Control of \x02#{live_channel.name}\x02 has been recovered. Join the channel if you are not already there."
    )
  end

  defp reconcile_operator(channel, membership, target, founder, users) do
    should_op? = target.pid == founder.pid
    currently_op? = :o in membership.modes

    if should_op? != currently_op? do
      modes = if should_op?, do: [:o | membership.modes], else: List.delete(membership.modes, :o)
      UserChannels.update(membership, %{modes: modes})

      mode = if should_op?, do: "+o", else: "-o"

      %Message{command: "MODE", params: [channel.name, mode, target.nick]}
      |> Dispatcher.broadcast(:chanserv, users)
    end
  end
end
