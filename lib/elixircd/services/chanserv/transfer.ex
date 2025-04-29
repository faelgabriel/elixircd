defmodule ElixIRCd.Services.Chanserv.Transfer do
  @moduledoc """
  Module for the ChanServ TRANSFER command.
  This command allows channel founders to transfer ownership to another user.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User

  @command_name "TRANSFER"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name, new_founder]) do
    channel_name = String.downcase(channel_name)

    case check_channel_ownership(user, channel_name) do
      {:ok, registered_channel} ->
        transfer_channel(user, registered_channel, new_founder)

      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :not_founder} ->
        notify(user, "Access denied. You are not the founder of \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, [
      "Insufficient parameters for \x02TRANSFER\x02.",
      "Syntax: \x02TRANSFER <channel> [new_founder]\x02"
    ])
  end

  @spec check_channel_ownership(User.t(), String.t()) ::
          {:ok, RegisteredChannel.t()} | {:error, :not_founder | :registered_channel_not_found}
  defp check_channel_ownership(user, channel_name) do
    with {:ok, registered_channel} <- RegisteredChannels.get_by_name(channel_name),
         {:founder, true} <- {:founder, registered_channel.founder == user.identified_as} do
      {:ok, registered_channel}
    else
      {:founder, false} -> {:error, :not_founder}
      {:error, :registered_channel_not_found} -> {:error, :registered_channel_not_found}
    end
  end

  @spec transfer_channel(User.t(), RegisteredChannel.t(), String.t()) :: :ok
  defp transfer_channel(user, registered_channel, new_founder) do
    registered_nick_exists? =
      Memento.transaction!(fn ->
        case RegisteredNicks.get_by_nickname(new_founder) do
          {:ok, _registered_nick} -> true
          {:error, :registered_nick_not_found} -> false
        end
      end)

    if registered_nick_exists? do
      RegisteredChannels.update(registered_channel, %{
        founder: new_founder,
        successor: nil
      })

      notify(user, [
        "Channel \x02#{registered_channel.name}\x02 has been transferred to \x02#{new_founder}\x02.",
        "They are now the new channel founder."
      ])

      Logger.info("Channel transferred: #{registered_channel.name} from #{user.identified_as} to #{new_founder}")
    else
      notify(user, "The nickname \x02#{new_founder}\x02 is not registered.")
    end
  end
end
