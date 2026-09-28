defmodule ElixIRCd.Services.Chanserv.Transfer do
  @moduledoc """
  This module defines the ChanServ TRANSFER command.

  TRANSFER allows channel founders to transfer ownership to another user.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User

  @command_name "TRANSFER"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name, target_new_founder]) do
    case check_channel_ownership(user, channel_name) do
      {:ok, registered_channel} ->
        transfer_channel(user, registered_channel, target_new_founder)

      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :not_founder} ->
        notify(user, "Access denied. You are not the founder of \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name, channel_name]) do
    result =
      Memento.transaction!(fn ->
        with {:ok, channel} <- RegisteredChannels.get_by_name_for_update(channel_name),
             true <- channel.successor == user.identified_as,
             :ok <- founder_inactive(channel.founder) do
          RegisteredChannels.update(channel, %{founder: user.identified_as, successor: nil})
          RegisteredChannelAccesses.delete(channel.name, user.identified_as)
          :ok
        else
          {:error, :registered_channel_not_found} -> {:error, :not_found}
          _ -> {:error, :not_eligible}
        end
      end)

    case result do
      :ok ->
        notify(user, "You have claimed founder ownership of \x02#{channel_name}\x02.")

      {:error, :not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :not_eligible} ->
        notify(user, "Successor claim is unavailable while the founder is active or you are not the successor.")
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
  defp transfer_channel(user, registered_channel, target_new_founder) do
    case RegisteredNicks.get_by_nickname(target_new_founder) do
      {:ok, registered_nick} ->
        RegisteredChannels.update(registered_channel, %{
          founder: registered_nick.account_name,
          successor: nil
        })

        RegisteredChannelAccesses.delete(registered_channel.name, registered_nick.account_name)

        notify(user, [
          "Channel \x02#{registered_channel.name}\x02 has been transferred to \x02#{registered_nick.account_name}\x02.",
          "They are now the new channel founder."
        ])

      {:error, :registered_nick_not_found} ->
        notify(user, "The nickname \x02#{target_new_founder}\x02 is not registered.")
    end
  end

  defp founder_inactive(account_name) do
    days = Application.fetch_env!(:elixircd, :services)[:chanserv][:successor_claim_after_days]

    with [] <- Users.get_by_identified_as(account_name),
         {:ok, account} <- RegisteredNicks.get_by_nickname(account_name) do
      last_active = account.last_seen_at || account.created_at
      if DateTime.diff(DateTime.utc_now(), last_active, :day) >= days, do: :ok, else: {:error, :founder_active}
    else
      _ -> {:error, :founder_active}
    end
  end
end
