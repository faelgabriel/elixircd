defmodule ElixIRCd.ServerLink.RemoteWho do
  @moduledoc "Builds WHO and WHOX replies from committed remote user and channel views."

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.RemoteUser
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  @whox_fields ~w(t c u i h s n f d l a o r)

  @doc "Returns remote WHO rows for a named channel, including remote-only channels."
  @spec channel_messages(map(), String.t(), map()) :: [Message.t()]
  def channel_messages(requester, channel_name, query) do
    case ChannelDirectory.get(channel_name) do
      {:ok, view} ->
        channel_rows(requester, channel_name, view, query)

      _ ->
        []
    end
  end

  defp channel_rows(requester, channel_name, view, query) do
    channel_key = CaseMapping.normalize(channel_name)
    membership = local_membership(requester, channel_key)

    if secret?(view, channel_key) and is_nil(membership) do
      []
    else
      view.remote_members
      |> Enum.filter(&visible_member?(&1, view, channel_key, membership))
      |> Enum.map(&member_row(&1, view.channel["name"]))
      |> maybe_filter_operators(query, requester)
      |> sorted_rows()
      |> Enum.map(&build_message(requester, &1, query))
    end
  end

  defp member_row(member, channel_name) do
    remote = %RemoteUser{origin: member.origin, uid: member.member["uid"], user: member.user}
    {remote, channel_name, member.effective_modes}
  end

  @doc "Returns remote WHO rows matching a user mask without exposing hidden members."
  @spec mask_messages(map(), String.t(), map()) :: [Message.t()]
  def mask_messages(requester, mask, query) do
    case Directory.all() do
      remotes when is_list(remotes) ->
        viewer_keys = requester.pid |> UserChannels.get_by_user_pid() |> MapSet.new(& &1.channel_name_key)

        views =
          case ChannelDirectory.all() do
            entries when is_list(entries) -> entries
            :unavailable -> []
          end

        remotes
        |> Enum.filter(fn remote ->
          mask_matches?(remote.user, requester, mask) and visible_user?(remote, requester, mask, views, viewer_keys)
        end)
        |> Enum.map(fn remote -> {remote, visible_channel(remote, requester, mask, views, viewer_keys)} end)
        |> Enum.map(fn {remote, channel} -> {remote, channel_name(channel), member_modes(channel)} end)
        |> maybe_filter_operators(query, requester)
        |> sorted_rows()
        |> Enum.map(&build_message(requester, &1, query))

      :unavailable ->
        []
    end
  end

  defp sorted_rows(rows),
    do:
      Enum.sort_by(rows, fn {remote, _, _} ->
        {CaseMapping.normalize(remote.user["nick"]), remote.origin, remote.uid}
      end)

  defp local_membership(requester, channel_key) do
    case UserChannels.get_by_user_pid_and_channel_name(requester.pid, channel_key) do
      {:ok, membership} -> membership
      _ -> nil
    end
  end

  defp visible_member?(member, view, channel_key, membership) do
    remote = member.user
    invisible? = "i" in remote["modes"] and is_nil(membership)
    auditorium? = auditorium?(view, channel_key)
    remote_privileged? = privileged?(member.effective_modes)
    viewer_privileged? = not is_nil(membership) and privileged?(membership.modes)

    not invisible? and (not auditorium? or remote_privileged? or viewer_privileged?)
  end

  defp visible_user?(remote, requester, mask, views, viewer_keys) do
    "i" not in remote.user["modes"] or
      CaseMapping.normalize(mask) == CaseMapping.normalize(remote.user["nick"]) or
      Enum.any?(views, fn view ->
        key = CaseMapping.normalize(view.channel["name"])

        if MapSet.member?(viewer_keys, key) do
          membership = local_membership(requester, key)
          member = Enum.find(view.remote_members, &(&1.origin == remote.origin and &1.member["uid"] == remote.uid))
          member && visible_member?(member, view, key, membership)
        else
          false
        end
      end)
  end

  defp mask_matches?(payload, requester, mask) do
    target = UserPayload.public_view(payload)

    Protocol.match_user_mask?(target, Protocol.normalize_mask(mask)) or
      (not String.contains?(mask, ["!", "@"]) and
         (Protocol.match_ascii_glob?(target.ident, mask) or
            Protocol.match_ascii_glob?(target.realname, mask) or
            Protocol.match_ascii_glob?(Protocol.display_hostname(target, requester), mask)))
  end

  defp visible_channel(remote, requester, mask, views, viewer_keys) do
    if CaseMapping.normalize(mask) == CaseMapping.normalize(remote.user["nick"]) do
      Enum.find_value(views, &visible_channel_in_view(&1, remote, requester, viewer_keys))
    end
  end

  defp visible_channel_in_view(view, remote, requester, viewer_keys) do
    key = CaseMapping.normalize(view.channel["name"])
    membership = if MapSet.member?(viewer_keys, key), do: local_membership(requester, key)
    member = Enum.find(view.remote_members, &(&1.origin == remote.origin and &1.member["uid"] == remote.uid))

    visible? =
      member != nil and (not hidden?(view, key) or not is_nil(membership)) and
        visible_member?(member, view, key, membership)

    if visible?, do: {view.channel["name"], member.effective_modes}
  end

  defp channel_name(nil), do: "*"
  defp channel_name({name, _modes}), do: name
  defp member_modes(nil), do: []
  defp member_modes({_name, modes}), do: modes

  defp secret?(view, key), do: "s" in selected_modes(view) or :s in local_modes(key)

  defp hidden?(view, key),
    do: Enum.any?(["s", "p"], &(&1 in selected_modes(view))) or Enum.any?([:s, :p], &(&1 in local_modes(key)))

  defp auditorium?(view, key), do: "u" in selected_modes(view) or :u in local_modes(key)
  defp selected_modes(view), do: Enum.map(view.channel["modes"], & &1["name"])

  defp local_modes(key) do
    case Channels.get_by_name(key) do
      {:ok, channel} -> channel.modes
      _ -> []
    end
  end

  defp privileged?(modes), do: :o in modes or :v in modes or "o" in modes or "v" in modes

  defp maybe_filter_operators(rows, %{operator_only: true}, requester) do
    Enum.filter(rows, fn {remote, _, _} ->
      remote.user |> UserPayload.public_view() |> Protocol.irc_operator_visible?(requester)
    end)
  end

  defp maybe_filter_operators(rows, _query, _requester), do: rows

  defp build_message(requester, {remote, channel, modes}, %{fields: fields} = query) do
    target = UserPayload.public_view(remote.user)

    if fields == [] do
      %Message{
        command: :rpl_whoreply,
        params: [
          requester.nick,
          channel,
          target.ident,
          Protocol.display_hostname(target, requester),
          remote.origin,
          target.nick,
          status(requester, target, modes)
        ],
        trailing: "0 #{target.realname}"
      }
    else
      values =
        @whox_fields
        |> Enum.filter(&(&1 in fields and &1 != "r"))
        |> Enum.map(&whox_value(&1, requester, target, remote.origin, channel, modes, query))

      %Message{
        command: :rpl_whospcrpl,
        params: [requester.nick | values],
        trailing: if("r" in fields, do: target.realname)
      }
    end
  end

  defp whox_value("t", _requester, _target, _origin, _channel, _modes, query), do: query.token
  defp whox_value("c", _requester, _target, _origin, channel, _modes, _query), do: channel
  defp whox_value("u", _requester, target, _origin, _channel, _modes, _query), do: target.ident
  defp whox_value("i", _requester, _target, _origin, _channel, _modes, _query), do: "255.255.255.255"

  defp whox_value("h", requester, target, _origin, _channel, _modes, _query),
    do: Protocol.display_hostname(target, requester)

  defp whox_value("s", _requester, _target, origin, _channel, _modes, _query), do: origin
  defp whox_value("n", _requester, target, _origin, _channel, _modes, _query), do: target.nick
  defp whox_value("f", requester, target, _origin, _channel, modes, _query), do: status(requester, target, modes)
  defp whox_value("d", _requester, _target, _origin, _channel, _modes, _query), do: "0"
  defp whox_value("l", _requester, _target, _origin, _channel, _modes, _query), do: "0"
  defp whox_value("a", _requester, target, _origin, _channel, _modes, _query), do: target.identified_as || "0"

  defp whox_value("o", _requester, _target, _origin, _channel, modes, _query) do
    cond do
      "o" in modes -> "2"
      "v" in modes -> "1"
      true -> "0"
    end
  end

  defp status(requester, target, modes) do
    away = if target.away_message, do: "G", else: "H"
    operator = if Protocol.irc_operator_visible?(target, requester), do: "*", else: ""
    bot = if :B in target.modes, do: "B", else: ""
    prefixes = if("o" in modes, do: "@", else: "") <> if("v" in modes, do: "+", else: "")
    prefixes = if "multi-prefix" in requester.capabilities, do: prefixes, else: String.slice(prefixes, 0, 1)
    away <> operator <> bot <> prefixes
  end
end
