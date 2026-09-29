defmodule ElixIRCd.ServerLink.RemoteWhois do
  @moduledoc "Builds WHOIS replies from committed remote user and channel records."

  alias ElixIRCd.Message
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.RemoteUser
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  @doc "Returns only details that the home server has replicated and the requester may see."
  @spec messages(User.t(), RemoteUser.t()) :: [Message.t()]
  def messages(requester, remote) do
    target = UserPayload.public_view(remote.user)

    [
      %Message{
        command: :rpl_whoisuser,
        params: [requester.nick, target.nick, target.ident, Protocol.display_hostname(target, requester), "*"],
        trailing: target.realname
      }
    ]
    |> maybe_add_actual_host(requester, target)
    |> maybe_add_modes(requester, target)
    |> maybe_add_registration(requester, target)
    |> maybe_add_bot(requester, target)
    |> add_channels(requester, remote)
    |> Kernel.++([
      %Message{
        command: :rpl_whoisserver,
        params: [requester.nick, target.nick, remote.origin],
        trailing: "Elixir IRC daemon"
      }
    ])
    |> maybe_add_away(requester, target)
    |> maybe_add_operator(requester, target)
  end

  defp maybe_add_actual_host(messages, requester, target) do
    if Protocol.irc_operator?(requester) and :x in target.modes do
      messages ++
        [
          %Message{
            command: :rpl_whoisactually,
            params: [requester.nick, target.nick, target.hostname],
            trailing: "is actually using host"
          }
        ]
    else
      messages
    end
  end

  defp maybe_add_modes(messages, requester, target) do
    if Protocol.irc_operator?(requester) do
      modes = "+" <> (target.modes |> Enum.sort() |> Enum.map_join(&ModeRegistry.encode!(:user, &1)))

      messages ++
        [%Message{command: :rpl_whoismodes, params: [requester.nick, target.nick], trailing: "is using modes #{modes}"}]
    else
      messages
    end
  end

  defp maybe_add_registration(messages, requester, target) do
    messages =
      if :r in target.modes do
        messages ++
          [
            %Message{
              command: :rpl_whoisregnick,
              params: [requester.nick, target.nick],
              trailing: "has identified for this nick"
            }
          ]
      else
        messages
      end

    if target.identified_as do
      messages ++
        [
          %Message{
            command: :rpl_whoisaccount,
            params: [requester.nick, target.nick, target.identified_as],
            trailing: "is logged in as #{target.identified_as}"
          }
        ]
    else
      messages
    end
  end

  defp maybe_add_bot(messages, requester, target) do
    if :B in target.modes do
      messages ++
        [%Message{command: :rpl_whoisbot, params: [requester.nick, target.nick], trailing: "Is a bot on this network"}]
    else
      messages
    end
  end

  defp add_channels(messages, requester, remote) do
    membership_keys = requester.pid |> UserChannels.get_by_user_pid() |> MapSet.new(& &1.channel_name_key)

    words =
      case ChannelDirectory.all() do
        views when is_list(views) ->
          views
          |> Enum.flat_map(&visible_channel_words(&1, remote, membership_keys, requester))
          |> Enum.sort()

        :unavailable ->
          []
      end

    if words == [] do
      messages
    else
      template = %Message{command: :rpl_whoischannels, params: [requester.nick, remote.user["nick"]]}
      messages ++ Protocol.chunk_message_words(template, words)
    end
  end

  defp visible_channel_words(view, remote, membership_keys, requester) do
    channel = view.channel
    name = channel["name"]
    key = CaseMapping.normalize(name)

    member =
      Enum.find(view.remote_members, fn entry ->
        entry.origin == remote.origin and entry.member["uid"] == remote.uid
      end)

    if member && channel_visible?(channel, key, membership_keys) do
      prefix = membership_prefix(member.effective_modes, "multi-prefix" in requester.capabilities)
      [prefix <> name]
    else
      []
    end
  end

  defp channel_visible?(channel, key, membership_keys) do
    selected_modes = Enum.map(channel["modes"], & &1["name"])

    local_hidden? =
      case Channels.get_by_name(channel["name"]) do
        {:ok, local} -> :s in local.modes or :p in local.modes
        _ -> false
      end

    MapSet.member?(membership_keys, key) or
      (not local_hidden? and "s" not in selected_modes and "p" not in selected_modes)
  end

  defp membership_prefix(modes, true) do
    if("o" in modes, do: "@", else: "") <> if "v" in modes, do: "+", else: ""
  end

  defp membership_prefix(modes, false) do
    cond do
      "o" in modes -> "@"
      "v" in modes -> "+"
      true -> ""
    end
  end

  defp maybe_add_away(messages, requester, target) do
    if target.away_message do
      messages ++ [%Message{command: :rpl_away, params: [requester.nick, target.nick], trailing: target.away_message}]
    else
      messages
    end
  end

  defp maybe_add_operator(messages, requester, target) do
    if Protocol.irc_operator_visible?(target, requester) do
      messages ++
        [%Message{command: :rpl_whoisoperator, params: [requester.nick, target.nick], trailing: "is an IRC operator"}]
    else
      messages
    end
  end
end
