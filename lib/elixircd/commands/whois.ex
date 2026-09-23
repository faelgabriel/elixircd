defmodule ElixIRCd.Commands.Whois do
  @moduledoc """
  This module defines the WHOIS command.

  WHOIS returns detailed information about a specific user.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1, display_hostname: 2, irc_operator?: 1, irc_operator_visible?: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Metadata
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping

  @command "WHOIS"

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: @command}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), @command], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: @command, params: [server, target_nick | _rest]}) do
    hostname = Application.fetch_env!(:elixircd, :server)[:hostname]

    if CaseMapping.normalize(server) == CaseMapping.normalize(hostname) or
         match?({:ok, %{registered: true}}, Users.get_by_nick(server)) do
      handle(user, %Message{command: @command, params: [target_nick]})
    else
      %Message{command: :err_nosuchserver, params: [user.nick, server], trailing: "No such server"}
      |> Dispatcher.broadcast(:server, user)
    end
  end

  def handle(user, %{command: @command, params: [target_nick]}) do
    {target_user, target_user_channels_display} = get_target_user(user, target_nick)

    whois_message(user, target_nick, target_user, target_user_channels_display)

    %Message{command: :rpl_endofwhois, params: [user.nick, target_nick], trailing: "End of /WHOIS list."}
    |> Dispatcher.broadcast(:server, user)
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(User.t(), String.t(), User.t() | nil, [String.t()]) :: :ok
  def whois_message(user, target_nick, nil = _target_user, _target_user_channels_display) do
    %Message{command: :err_nosuchnick, params: [user.nick, target_nick], trailing: "No such nick"}
    |> Dispatcher.broadcast(:server, user)
  end

  def whois_message(user, _target_nick, target_user, target_user_channels_display) when target_user != nil do
    []
    |> add_whoisuser(user, target_user)
    |> maybe_add_whoismodes(user, target_user)
    |> maybe_add_whoisregnick(user, target_user)
    |> maybe_add_whoisaccount(user, target_user)
    |> add_metadata(user, target_user)
    |> maybe_add_whoisbot(user, target_user)
    |> maybe_add_whoischannels(user, target_user, target_user_channels_display)
    |> add_whoisserver(user, target_user)
    |> maybe_add_away(user, target_user)
    |> maybe_add_whoisoperator(user, target_user)
    |> add_whoisidle(user, target_user)
    |> Dispatcher.broadcast(:server, user)
  end

  defp add_metadata(messages, user, %User{pid: pid} = target_user) when is_pid(pid),
    do: messages ++ Metadata.whois_messages(user, target_user)

  defp add_metadata(messages, _user, _target_user), do: messages

  @spec add_whoisuser([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp add_whoisuser(messages, user, target_user) do
    whoisuser = %Message{
      command: :rpl_whoisuser,
      params: [user.nick, target_user.nick, target_user.ident, display_hostname(target_user, user), "*"],
      trailing: target_user.realname
    }

    messages = messages ++ [whoisuser]

    if irc_operator?(user) and :x in target_user.modes do
      whoisactually = %Message{
        command: :rpl_whoisactually,
        params: [user.nick, target_user.nick, target_user.hostname],
        trailing: "is actually using host"
      }

      messages ++ [whoisactually]
    else
      messages
    end
  end

  @spec maybe_add_whoismodes([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_whoismodes(messages, user, target_user) do
    if User.same_identity?(user, target_user) or irc_operator?(user) do
      modes = "+" <> (target_user.modes |> Enum.sort() |> Enum.map_join(&ModeRegistry.encode!(:user, &1)))

      messages ++
        [
          %Message{
            command: :rpl_whoismodes,
            params: [user.nick, target_user.nick],
            trailing: "is using modes #{modes}"
          }
        ]
    else
      messages
    end
  end

  @spec maybe_add_whoisregnick([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_whoisregnick(messages, user, target_user) do
    if :r in target_user.modes do
      messages ++
        [
          %Message{
            command: :rpl_whoisregnick,
            params: [user.nick, target_user.nick],
            trailing: "has identified for this nick"
          }
        ]
    else
      messages
    end
  end

  @spec maybe_add_whoisaccount([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_whoisaccount(messages, user, target_user) do
    if target_user.identified_as do
      messages ++
        [
          %Message{
            command: :rpl_whoisaccount,
            params: [user.nick, target_user.nick, target_user.identified_as],
            trailing: "is logged in as #{target_user.identified_as}"
          }
        ]
    else
      messages
    end
  end

  @spec maybe_add_whoisbot([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_whoisbot(messages, user, target_user) do
    if :B in target_user.modes do
      messages ++
        [%Message{command: :rpl_whoisbot, params: [user.nick, target_user.nick], trailing: "Is a bot on this server"}]
    else
      messages
    end
  end

  @spec maybe_add_whoischannels([Message.t()], User.t(), User.t(), [String.t()]) :: [Message.t()]
  defp maybe_add_whoischannels(messages, _user, _target_user, []), do: messages

  defp maybe_add_whoischannels(messages, user, target_user, target_user_channels_display) do
    messages ++
      [
        %Message{
          command: :rpl_whoischannels,
          params: [user.nick, target_user.nick],
          trailing: target_user_channels_display |> Enum.join(" ")
        }
      ]
  end

  @spec add_whoisserver([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp add_whoisserver(messages, user, target_user) do
    hostname = Application.fetch_env!(:elixircd, :server)[:hostname]

    messages ++
      [
        %Message{
          command: :rpl_whoisserver,
          params: [user.nick, target_user.nick, hostname],
          trailing: "Elixir IRC daemon"
        }
      ]
  end

  @spec maybe_add_away([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_away(messages, user, target_user) do
    if target_user.away_message != nil do
      messages ++
        [%Message{command: :rpl_away, params: [user.nick, target_user.nick], trailing: target_user.away_message}]
    else
      messages
    end
  end

  @spec maybe_add_whoisoperator([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_whoisoperator(messages, user, target_user) do
    if irc_operator_visible?(target_user, user) do
      messages ++
        [%Message{command: :rpl_whoisoperator, params: [user.nick, target_user.nick], trailing: "is an IRC operator"}]
    else
      messages
    end
  end

  @spec add_whoisidle([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp add_whoisidle(messages, user, target_user) do
    idle_seconds = (:erlang.system_time(:second) - target_user.last_activity) |> to_string()
    signon_time = target_user.registered_at |> DateTime.to_unix() |> to_string()

    messages ++
      [
        %Message{
          command: :rpl_whoisidle,
          params: [user.nick, target_user.nick, idle_seconds, signon_time],
          trailing: "seconds idle, signon time"
        }
      ]
  end

  @spec get_target_user(User.t(), String.t()) :: {User.t() | nil, [String.t()]}
  defp get_target_user(user, target_nick) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} ->
        process_target_user(user, target_user)

      _ ->
        network_target_user(user, target_nick)
    end
  end

  defp network_target_user(user, target_nick) do
    with manager when is_pid(manager) <- Process.whereis(Manager),
         {:ok, runtime} <- View.runtime(manager) do
      case View.user_by_nick(runtime, target_nick) do
        {:ok, _uid, target_user} ->
          {target_user, network_target_channels(user, target_user, runtime)}

        _ ->
          network_service_target(user, target_nick, runtime)
      end
    else
      _ -> {nil, []}
    end
  end

  defp network_service_target(user, target_nick, runtime) do
    case View.chanserv_user_by_nick(runtime, target_nick) do
      {:ok, service} ->
        channels = View.guarded_service_channels(runtime, user.uid) |> Enum.map(& &1.name)
        {service, channels}

      _ ->
        {nil, []}
    end
  end

  defp network_target_channels(user, target_user, runtime) do
    viewer_channels = network_membership_keys(runtime, user.uid)
    target_channels = network_user_channels(runtime, target_user.uid)

    target_channels
    |> Enum.filter(fn {channel, _membership} ->
      channel.name_key in viewer_channels or (:s not in channel.modes and :p not in channel.modes)
    end)
    |> Enum.map(fn {channel, membership} ->
      membership_prefix(membership, "multi-prefix" in user.capabilities) <> channel.name
    end)
    |> Enum.reverse()
  end

  defp network_membership_keys(runtime, uid) do
    case runtime.memberships[uid] do
      %{entries: entries} -> Enum.map(entries, &CaseMapping.normalize(&1["channel"]))
      _ -> []
    end
  end

  defp network_user_channels(runtime, uid) do
    case runtime.memberships[uid] do
      %{entries: entries} ->
        Enum.flat_map(entries, &network_user_channel(runtime, uid, &1))

      _ ->
        []
    end
  end

  defp network_user_channel(runtime, uid, entry) do
    with {:ok, channel, _runtime_channel} <- View.channel(runtime, entry["channel"]),
         {:ok, membership} <- View.membership(runtime, uid, entry["channel"]) do
      [{channel, membership}]
    else
      _ -> []
    end
  end

  @spec process_target_user(User.t(), User.t()) :: {User.t() | nil, [String.t()]}
  defp process_target_user(user, target_user) do
    channels_by_pid =
      [user.pid, target_user.pid]
      |> UserChannels.get_by_user_pids()
      |> Enum.group_by(& &1.user_pid, & &1)

    user_channels = Map.get(channels_by_pid, user.pid, [])
    target_user_channels = Map.get(channels_by_pid, target_user.pid, [])

    user_channels_keys = Enum.map(user_channels, & &1.channel_name_key)
    target_user_channels_keys = Enum.map(target_user_channels, & &1.channel_name_key)

    # Exact nickname WHOIS remains available with +i/+H; channel and oper details are filtered separately.
    if target_user_channels_keys == [] do
      {target_user, []}
    else
      channel_map = fetch_channel_map(user_channels_keys, target_user_channels_keys)
      channel_names = filter_and_resolve_channel_names(user_channels_keys, target_user_channels_keys, channel_map)

      displayed =
        Enum.map(channel_names, fn name ->
          membership =
            Enum.find(target_user_channels, &(&1.channel_name_key == CaseMapping.normalize(name)))

          prefix = membership_prefix(membership, "multi-prefix" in user.capabilities)

          prefix <> name
        end)

      {target_user, displayed}
    end
  end

  @spec membership_prefix(UserChannel.t(), boolean()) :: String.t()
  defp membership_prefix(membership, true = _multi_prefix) do
    []
    |> maybe_add_membership_prefix(:o in membership.modes, "@")
    |> maybe_add_membership_prefix(:v in membership.modes, "+")
    |> Enum.reverse()
    |> Enum.join("")
  end

  defp membership_prefix(membership, false = _multi_prefix) do
    cond do
      :o in membership.modes -> "@"
      :v in membership.modes -> "+"
      true -> ""
    end
  end

  @spec maybe_add_membership_prefix([String.t()], boolean(), String.t()) :: [String.t()]
  defp maybe_add_membership_prefix(prefixes, true, prefix), do: [prefix | prefixes]
  defp maybe_add_membership_prefix(prefixes, false, _prefix), do: prefixes

  @spec fetch_channel_map([String.t()], [String.t()]) :: map()
  defp fetch_channel_map(user_channels_keys, target_user_channels_keys) do
    all_keys = (user_channels_keys ++ target_user_channels_keys) |> Enum.uniq()

    case Channels.get_by_names(all_keys) do
      [] -> %{}
      channels -> Map.new(channels, &{&1.name_key, &1})
    end
  end

  # Secret (+s) and private (+p) channels show only to members. Orphaned references are dropped.
  @spec filter_and_resolve_channel_names([String.t()], [String.t()], map()) :: [String.t()]
  defp filter_and_resolve_channel_names(user_channels_keys, target_user_channels_keys, channel_map) do
    user_channels_set = MapSet.new(user_channels_keys)

    target_user_channels_keys
    |> Enum.filter(&Map.has_key?(channel_map, &1))
    |> Enum.map(&process_channel_visibility(&1, channel_map, user_channels_set))
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
  end

  @spec process_channel_visibility(String.t(), map(), MapSet.t()) :: String.t() | nil
  defp process_channel_visibility(channel_name_key, channel_map, user_channels_set) do
    channel = Map.get(channel_map, channel_name_key)
    is_hidden = :s in channel.modes or :p in channel.modes
    user_in_channel = MapSet.member?(user_channels_set, channel_name_key)

    if is_hidden and not user_in_channel, do: nil, else: channel.name
  end
end
