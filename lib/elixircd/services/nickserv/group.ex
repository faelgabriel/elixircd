defmodule ElixIRCd.Services.Nickserv.Group do
  @moduledoc """
  This module defines the NickServ GROUP command.

  GROUP adds the current nickname to the authenticated account.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv,
    only: [belongs_to_account?: 2, get_account_nick: 1, grouped?: 1, notify: 2, notify_account_change: 2]

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.NickAccess
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, ["GROUP" | _]) do
    notify(user, [
      "You must identify to NickServ before using the GROUP command.",
      "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify."
    ])
  end

  def handle(user, ["GROUP"]) do
    handle_group(user, nil)
  end

  def handle(user, ["GROUP", current_nick_password]) do
    handle_group(user, current_nick_password)
  end

  def handle(user, ["GROUP" | _]) do
    notify(user, [
      "Too many parameters for \x02GROUP\x02.",
      "Syntax: \x02GROUP [current-nick-password]\x02"
    ])
  end

  @spec handle_group(User.t(), String.t() | nil) :: :ok
  defp handle_group(user, current_nick_password) do
    case RegisteredNicks.get_by_nickname(user.identified_as) do
      {:ok, account_nick} ->
        group_current_nick(user, account_nick, current_nick_password)

      {:error, :registered_nick_not_found} ->
        notify(user, "Your account could not be resolved. Please try identifying again.")
    end
  end

  @spec group_current_nick(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp group_current_nick(user, account_nick, current_nick_password) do
    if is_nil(account_nick.verify_code) do
      group_nick_if_available(user, account_nick, current_nick_password)
    else
      notify(user, [
        "Your account \x02#{account_nick.account_name}\x02 has not been verified yet.",
        "Please verify it first with \x02/msg NickServ VERIFY #{account_nick.nickname} <code>\x02"
      ])
    end
  end

  @spec group_nick_if_available(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp group_nick_if_available(user, account_nick, current_nick_password) do
    case RegisteredNicks.get_by_nickname(user.nick) do
      {:ok, registered_nick} ->
        cond do
          registered_nick.nickname_key == account_nick.nickname_key ->
            notify(user, "Your current nickname is already the primary nickname of your account.")

          belongs_to_account?(registered_nick, account_nick.account_name) ->
            notify(user, "Nick \x02#{registered_nick.nickname}\x02 is already grouped with your account.")

          true ->
            group_registered_nick(user, registered_nick, account_nick, current_nick_password)
        end

      {:error, :registered_nick_not_found} ->
        create_grouped_nick(user, account_nick)
    end
  end

  @spec group_registered_nick(User.t(), RegisteredNick.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp group_registered_nick(user, registered_nick, account_nick, current_nick_password) do
    cond do
      is_nil(current_nick_password) ->
        notify(user, [
          "Nick \x02#{registered_nick.nickname}\x02 is already registered.",
          "To group it into your current account, repeat the command with that nick's password.",
          "Syntax: \x02GROUP [current-nick-password]\x02"
        ])

      moving_group_primary_with_aliases?(registered_nick) ->
        notify(user, [
          "Nick \x02#{registered_nick.nickname}\x02 is the primary nickname of another account.",
          "Ungroup or drop the other nicknames in that account before grouping this nick."
        ])

      true ->
        verify_registered_nick_password(user, registered_nick, account_nick, current_nick_password)
    end
  end

  @spec verify_registered_nick_password(User.t(), RegisteredNick.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_registered_nick_password(user, registered_nick, account_nick, current_nick_password) do
    case get_account_nick(registered_nick) do
      {:ok, source_account_nick} ->
        if Argon2.verify_pass(current_nick_password, source_account_nick.password_hash) do
          regroup_registered_nick(user, registered_nick, account_nick)
        else
          notify(user, "Authentication failed. Invalid password for \x02#{registered_nick.nickname}\x02.")
        end

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{registered_nick.nickname}\x02 is not registered.")
    end
  end

  @spec moving_group_primary_with_aliases?(RegisteredNick.t()) :: boolean()
  defp moving_group_primary_with_aliases?(registered_nick) do
    !grouped?(registered_nick) and
      length(RegisteredNicks.get_by_account_name(registered_nick.account_name)) > 1
  end

  @spec create_grouped_nick(User.t(), RegisteredNick.t()) :: :ok
  defp create_grouped_nick(user, account_nick) do
    RegisteredNicks.create(%{
      nickname: user.nick,
      account_name: account_nick.account_name,
      password_hash: account_nick.password_hash,
      email: account_nick.email,
      registered_by: user_mask(user),
      verify_code: nil,
      verified_at: account_nick.verified_at,
      last_seen_at: DateTime.utc_now(),
      settings: account_nick.settings
    })

    notify(user, [
      "Nick \x02#{user.nick}\x02 has been grouped into account \x02#{account_nick.account_name}\x02.",
      "You can now use it as an alias for your account."
    ])
  end

  @spec regroup_registered_nick(User.t(), RegisteredNick.t(), RegisteredNick.t()) :: :ok
  defp regroup_registered_nick(user, registered_nick, account_nick) do
    previous_account_name = registered_nick.account_name

    RegisteredNicks.update(registered_nick, %{
      account_name: account_nick.account_name,
      password_hash: account_nick.password_hash,
      email: account_nick.email,
      verify_code: nil,
      verified_at: account_nick.verified_at,
      last_seen_at: DateTime.utc_now(),
      settings: account_nick.settings
    })

    if previous_account_name != account_nick.account_name do
      migrate_account_state(previous_account_name, account_nick.account_name)
    end

    notify(user, [
      "Nick \x02#{registered_nick.nickname}\x02 has been grouped into account \x02#{account_nick.account_name}\x02.",
      "You can now use it as an alias for your account."
    ])
  end

  @spec migrate_account_state(String.t(), String.t()) :: :ok
  defp migrate_account_state(previous_account_name, new_account_name) do
    move_access_entries(previous_account_name, new_account_name)
    move_channel_registrations(previous_account_name, new_account_name)
    move_identified_users(previous_account_name, new_account_name)
    :ok
  end

  @spec move_access_entries(String.t(), String.t()) :: :ok
  defp move_access_entries(previous_account_name, new_account_name) do
    NickAccesses.get_by_account_name(previous_account_name)
    |> Enum.each(fn access_entry ->
      maybe_copy_access_entry(new_account_name, access_entry)
    end)

    NickAccesses.delete_by_account_name(previous_account_name)
  end

  @spec maybe_copy_access_entry(String.t(), NickAccess.t()) :: :ok
  defp maybe_copy_access_entry(new_account_name, access_entry) do
    if is_nil(NickAccesses.get_by_account_name_and_mask(new_account_name, access_entry.mask)) do
      NickAccesses.create(%{
        nickname: new_account_name,
        mask: access_entry.mask,
        created_at: access_entry.created_at
      })
    end

    :ok
  end

  @spec move_channel_registrations(String.t(), String.t()) :: :ok
  defp move_channel_registrations(previous_account_name, new_account_name) do
    RegisteredChannels.get_by_founder(previous_account_name)
    |> Enum.each(fn channel ->
      attrs =
        if channel.successor == previous_account_name do
          %{founder: new_account_name, successor: new_account_name}
        else
          %{founder: new_account_name}
        end

      RegisteredChannels.update(channel, attrs)
    end)

    RegisteredChannels.get_by_successor(previous_account_name)
    |> Enum.reject(&(&1.founder == previous_account_name))
    |> Enum.each(fn channel ->
      RegisteredChannels.update(channel, %{successor: new_account_name})
    end)

    :ok
  end

  @spec move_identified_users(String.t(), String.t()) :: :ok
  defp move_identified_users(previous_account_name, new_account_name) do
    Users.get_by_identified_as(previous_account_name)
    |> Enum.each(fn target_user ->
      updated_user = Users.update(target_user, %{identified_as: new_account_name})
      notify_account_change(updated_user, new_account_name)
    end)

    :ok
  end
end
