defmodule ElixIRCd.Services.Chanserv.Akick do
  @moduledoc "Persistent account and mask-based ChanServ auto-kick management."

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  import ElixIRCd.Utils.Protocol,
    only: [display_hostname: 1, match_user_mask?: 2, normalize_mask: 1, valid_mask_format?: 1]

  alias ElixIRCd.Repositories.RegisteredChannelAkicks
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Services.Chanserv.Channel.Moderation
  alias ElixIRCd.Tables.RegisteredChannelAkick
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Chanserv.Flags

  @max_entries 100

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, ["AKICK" | _]),
    do: notify(user, "You must be identified with NickServ to use this command.")

  def handle(user, ["AKICK", channel_name, action | args]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_moderation(registered_channel, user.identified_as, access_entries) do
      dispatch(user, registered_channel, access_entries, String.upcase(action), args)
    else
      {:error, :registered_channel_not_found} -> notify(user, "Channel \x02#{channel_name}\x02 is not registered.")
      {:error, :access_denied} -> notify(user, "Access denied for \x02#{channel_name}\x02.")
    end
  end

  def handle(user, ["AKICK" | _]), do: usage(user)

  @doc "Checks persistent AKICK entries during JOIN, including when the live channel was just recreated."
  @spec blocked?(String.t(), User.t()) :: boolean()
  def blocked?(channel_name, user) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, registered} ->
        blocked_for_registered?(registered, channel_name, user)

      {:error, :registered_channel_not_found} ->
        false
    end
  end

  defp blocked_for_registered?(registered, channel_name, user) do
    if Flags.founder?(registered, user.identified_as) do
      false
    else
      entries = RegisteredChannelAkicks.list(channel_name)

      access =
        if registered.settings.peace and entries != [],
          do: ChannelContext.get_access_entries(channel_name),
          else: %{}

      Enum.any?(entries, fn entry ->
        matches?(entry, user) and
          (not registered.settings.peace or
             Flags.access_rank(registered, user.identified_as, access) <
               Flags.access_rank(registered, entry.setter, access))
      end)
    end
  end

  defp dispatch(user, channel, access, "ADD", [target | reason_parts]) do
    {kind, value} = resolve_target(target)
    entries = RegisteredChannelAkicks.list(channel.name)

    reason =
      case Enum.join(reason_parts, " ") do
        "" -> nil
        text -> String.slice(text, 0, 200)
      end

    cond do
      kind == :invalid ->
        notify(user, "Specify a registered nickname, online nickname, or valid mask.")

      length(entries) >= @max_entries ->
        notify(user, "The AKICK list is full.")

      RegisteredChannelAkicks.get(channel.name, kind, value) != nil ->
        notify(user, "That AKICK entry already exists.")

      protected?(channel, user, access, kind, value) ->
        notify(user, "That target is protected by channel access.")

      true ->
        RegisteredChannelAkicks.put(RegisteredChannelAkick.new(channel.name, kind, value, reason, user.identified_as))
        notify(user, "AKICK entry for \x02#{value}\x02 added to \x02#{channel.name}\x02.")
        enforce(user, channel, access)
    end
  end

  defp dispatch(user, channel, _access, "DEL", [target]) do
    {kind, value} = resolve_target(target)

    case RegisteredChannelAkicks.get(channel.name, kind, value) do
      nil ->
        notify(user, "No matching AKICK entry was found.")

      entry ->
        RegisteredChannelAkicks.delete(entry)
        notify(user, "AKICK entry for \x02#{entry.target}\x02 removed from \x02#{channel.name}\x02.")
    end
  end

  defp dispatch(user, channel, _access, "LIST", []) do
    entries = RegisteredChannelAkicks.list(channel.name)
    notify(user, "AKICK list for \x02#{channel.name}\x02 (#{length(entries)} entries):")

    Enum.each(entries, fn entry ->
      notify(user, "#{entry.kind}: #{entry.target}#{if entry.reason, do: " - #{entry.reason}", else: ""}")
    end)
  end

  defp dispatch(user, channel, access, "ENFORCE", []), do: enforce(user, channel, access)

  defp dispatch(user, channel, _access, "CLEAR", []) do
    RegisteredChannelAkicks.delete_by_channel(channel.name)
    notify(user, "AKICK list cleared for \x02#{channel.name}\x02.")
  end

  defp dispatch(user, _channel, _access, _action, _args), do: usage(user)

  defp enforce(user, registered_channel, access) do
    case ChannelContext.get_online_channel_state(registered_channel.name) do
      {:ok, channel, _memberships, users} ->
        targets = Enum.filter(users, &blocked?(registered_channel.name, &1))

        case Moderation.ensure_peace(registered_channel, user, targets, access) do
          :ok ->
            count = Moderation.kick_targets(channel, targets, "ChanServ AKICK")
            notify(user, "AKICK enforced on \x02#{channel.name}\x02 (#{count} users removed).")

          {:error, :peace_denied} ->
            notify(user, "AKICK cannot remove a user protected by PEACE.")
        end

      {:error, :channel_not_in_use} ->
        notify(user, "AKICK will apply when \x02#{registered_channel.name}\x02 is joined.")
    end
  end

  defp resolve_target("$a:" <> account), do: registered_account(account)

  defp resolve_target(target) do
    case RegisteredNicks.get_by_nickname(target) do
      {:ok, nick} ->
        {:account, nick.account_name}

      {:error, :registered_nick_not_found} ->
        resolve_unregistered_target(target)
    end
  end

  defp resolve_unregistered_target(target) do
    case Users.get_by_nick(target) do
      {:ok, online} ->
        {:mask, normalize_mask("*!*@#{display_hostname(online)}")}

      {:error, :user_not_found} ->
        if String.contains?(target, ["!", "@", "*", "?"]) and valid_mask_format?(normalize_mask(target)),
          do: {:mask, normalize_mask(target)},
          else: {:invalid, target}
    end
  end

  defp registered_account(account) do
    case RegisteredNicks.get_by_nickname(account) do
      {:ok, nick} -> {:account, nick.account_name}
      _ -> {:invalid, account}
    end
  end

  defp protected?(channel, user, access, :account, account) do
    Flags.founder?(channel, account) or
      CaseMapping.normalize(user.identified_as) == CaseMapping.normalize(account) or
      (channel.settings.peace and
         Flags.access_rank(channel, account, access) >= Flags.access_rank(channel, user.identified_as, access))
  end

  defp protected?(channel, user, access, :mask, mask) do
    case ChannelContext.get_online_channel_state(channel.name) do
      {:ok, _live, _memberships, users} ->
        matched = Enum.filter(users, &match_user_mask?(&1, mask))

        Enum.any?(matched, &(&1.pid == user.pid or Flags.founder?(channel, &1.identified_as))) or
          Moderation.ensure_peace(channel, user, matched, access) != :ok

      _ ->
        false
    end
  end

  defp matches?(%{kind: :account, target_key: key}, user),
    do: is_binary(user.identified_as) and CaseMapping.normalize(user.identified_as) == key

  defp matches?(%{kind: :mask, target: mask}, user), do: match_user_mask?(user, mask)

  defp usage(user),
    do: notify(user, "Syntax: \x02AKICK <channel> {ADD <nick|mask> [reason]|DEL <nick|mask>|LIST|ENFORCE|CLEAR}\x02")
end
