defmodule ElixIRCd.Commands.Whois do
  @moduledoc """
  This module defines the WHOIS command.

  WHOIS returns detailed information about a specific user.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @command "WHOIS"

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: @command}) do
    Message.build(%{command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    Message.build(%{
      command: :err_needmoreparams,
      params: [user_reply(user), @command],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: @command, params: [target_nick | _rest]}) do
    {target_user, target_user_channels_display} = get_target_user(user, target_nick)

    whois_message(user, target_nick, target_user, target_user_channels_display)

    Message.build(%{
      command: :rpl_endofwhois,
      params: [user.nick, target_nick],
      trailing: "End of /WHOIS list."
    })
    |> Dispatcher.broadcast(:server, user)
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(User.t(), String.t(), User.t() | nil, [String.t()]) :: :ok
  def whois_message(user, target_nick, nil = _target_user, _target_user_channels_display) do
    Message.build(%{
      command: :err_nosuchnick,
      params: [user.nick, target_nick],
      trailing: "No such nick"
    })
    |> Dispatcher.broadcast(:server, user)
  end

  def whois_message(user, _target_nick, target_user, target_user_channels_display) when target_user != nil do
    []
    |> add_whoisuser(user, target_user)
    |> maybe_add_whoisregnick(user, target_user)
    |> maybe_add_whoisaccount(user, target_user)
    |> maybe_add_whoisbot(user, target_user)
    |> add_whoischannels(user, target_user, target_user_channels_display)
    |> add_whoisserver(user, target_user)
    |> maybe_add_away(user, target_user)
    |> maybe_add_whoisoperator(user, target_user)
    |> add_whoisidle(user, target_user)
    |> Dispatcher.broadcast(:server, user)
  end

  @spec add_whoisuser([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp add_whoisuser(messages, user, target_user) do
    messages ++
      [
        Message.build(%{
          command: :rpl_whoisuser,
          params: [user.nick, target_user.nick, target_user.ident, target_user.hostname, "*"],
          trailing: target_user.realname
        })
      ]
  end

  @spec maybe_add_whoisregnick([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_whoisregnick(messages, user, target_user) do
    if "r" in target_user.modes do
      messages ++
        [
          Message.build(%{
            command: :rpl_whoisregnick,
            params: [user.nick, target_user.nick],
            trailing: "has identified for this nick"
          })
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
          Message.build(%{
            command: :rpl_whoisaccount,
            params: [user.nick, target_user.nick, target_user.identified_as],
            trailing: "is logged in as #{target_user.identified_as}"
          })
        ]
    else
      messages
    end
  end

  @spec maybe_add_whoisbot([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_whoisbot(messages, user, target_user) do
    if "B" in target_user.modes do
      messages ++
        [
          Message.build(%{
            command: :rpl_whoisbot,
            params: [user.nick, target_user.nick],
            trailing: "Is a bot on this server"
          })
        ]
    else
      messages
    end
  end

  @spec add_whoischannels([Message.t()], User.t(), User.t(), [String.t()]) :: [Message.t()]
  defp add_whoischannels(messages, user, target_user, target_user_channels_display) do
    messages ++
      [
        Message.build(%{
          command: :rpl_whoischannels,
          params: [user.nick, target_user.nick],
          trailing: target_user_channels_display |> Enum.join(" ")
        })
      ]
  end

  @spec add_whoisserver([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp add_whoisserver(messages, user, target_user) do
    version = Application.spec(:elixircd, :vsn) || "dev"

    messages ++
      [
        Message.build(%{
          command: :rpl_whoisserver,
          params: [user.nick, target_user.nick, "ElixIRCd", version],
          trailing: "Elixir IRC daemon"
        })
      ]
  end

  @spec maybe_add_away([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_away(messages, user, target_user) do
    if target_user.away_message != nil do
      messages ++
        [
          Message.build(%{
            command: :rpl_away,
            params: [user.nick, target_user.nick],
            trailing: target_user.away_message
          })
        ]
    else
      messages
    end
  end

  @spec maybe_add_whoisoperator([Message.t()], User.t(), User.t()) :: [Message.t()]
  defp maybe_add_whoisoperator(messages, user, target_user) do
    if "o" in target_user.modes do
      messages ++
        [
          Message.build(%{
            command: :rpl_whoisoperator,
            params: [user.nick, target_user.nick],
            trailing: "is an IRC operator"
          })
        ]
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
        Message.build(%{
          command: :rpl_whoisidle,
          params: [user.nick, target_user.nick, idle_seconds, signon_time],
          trailing: "seconds idle, signon time"
        })
      ]
  end

  @spec get_target_user(User.t(), String.t()) :: {User.t() | nil, [String.t()]}
  defp get_target_user(user, target_nick) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} ->
        process_target_user(user, target_user)

      _ ->
        {nil, []}
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

    if target_user_visible?(user_channels_keys, target_user, target_user_channels_keys) do
      # Early return if target has no channels
      if target_user_channels_keys == [] do
        {target_user, []}
      else
        channel_map = fetch_channel_map(user_channels_keys, target_user_channels_keys)
        channel_names = filter_and_resolve_channel_names(user_channels_keys, target_user_channels_keys, channel_map)
        {target_user, channel_names}
      end
    else
      {nil, []}
    end
  end

  @spec fetch_channel_map([String.t()], [String.t()]) :: map()
  defp fetch_channel_map(user_channels_keys, target_user_channels_keys) do
    all_keys = (user_channels_keys ++ target_user_channels_keys) |> Enum.uniq()

    case Channels.get_by_names(all_keys) do
      [] -> %{}
      channels -> Map.new(channels, &{&1.name_key, &1})
    end
  end

  @spec target_user_visible?([String.t()], User.t(), [String.t()]) :: boolean()
  defp target_user_visible?(user_channels_keys, target_user, target_user_channels_keys) do
    if "i" in target_user.modes do
      # Check if users share any channels when target user is invisible
      shared_channels =
        MapSet.intersection(
          MapSet.new(user_channels_keys),
          MapSet.new(target_user_channels_keys)
        )

      not Enum.empty?(shared_channels)
    else
      # Target user is visible to everyone when not invisible
      true
    end
  end

  # Filters channel names based on visibility rules and resolves to actual channel names.
  # Secret channels ("s" mode) are only displayed if the requesting user is also in that channel.
  # Orphaned channel references (where the channel no longer exists) are filtered out.
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
    is_secret = "s" in channel.modes
    user_in_channel = MapSet.member?(user_channels_set, channel_name_key)

    # Don't show secret channels to users not in them
    if is_secret and not user_in_channel, do: nil, else: channel.name
  end
end
