defmodule ElixIRCd.Services.Chanserv.Drop do
  @moduledoc """
  Module for the ChanServ DROP command.
  This command allows channel founders to unregister their channels.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User

  @command_name "DROP"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name]) do
    case check_channel_ownership(user, channel_name) do
      {:ok, registered_channel} ->
        drop_channel(user, registered_channel)

      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :not_founder} ->
        notify(user, "Access denied. You are not the founder of \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, [
      "Insufficient parameters for \x02DROP\x02.",
      "Syntax: \x02DROP <channel>\x02"
    ])
  end

  @spec check_channel_ownership(User.t(), String.t()) ::
          {:ok, RegisteredChannel.t()} | {:error, :not_founder | :registered_channel_not_found}
  defp check_channel_ownership(user, channel_name) do
    with {:ok, registered_channel} <- RegisteredChannels.get_by_name(channel_name) do
      if registered_channel.founder == user.identified_as do
        {:ok, registered_channel}
      else
        {:error, :not_founder}
      end
    end
  end

  @spec drop_channel(User.t(), RegisteredChannel.t()) :: :ok
  defp drop_channel(user, registered_channel) do
    channel_name = registered_channel.name

    RegisteredChannels.delete(registered_channel)

    notify(user, [
      "Channel \x02#{channel_name}\x02 has been dropped.",
      "All channel data and settings have been permanently deleted."
    ])
  end
end
