defmodule ElixIRCd.Commands.Who do
  @moduledoc """
  This module defines the WHO command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, user_reply: 1, normalize_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "WHO"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WHO", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply(user), "WHO"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WHO", params: [target | filters]}) do
    case channel_name?(target) do
      true -> handle_who_channel(user, target, filters)
      false -> handle_who_mask(user, target, filters)
    end

    Message.build(%{
      prefix: :server,
      command: :rpl_endofwho,
      params: [user.nick, target],
      trailing: "End of WHO list"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec handle_who_channel(User.t(), String.t(), [String.t()]) :: :ok
  defp handle_who_channel(user, channel_name, filters) do
    Channels.get_by_name(channel_name)
    |> case do
      {:ok, channel} ->
        user_channels_list = UserChannels.get_by_channel_name(channel.name_key)
        users_in_channel = Enum.map(user_channels_list, & &1.user_pid) |> Users.get_by_pids()
        user_shares_channel? = Enum.any?(users_in_channel, &(&1.pid == user.pid))

        users_in_channel
        |> filter_out_hidden_channel(channel, user_shares_channel?)
        |> filter_out_invisible_users_for_channel(user_shares_channel?)
        |> maybe_filter_operators(filters)
        |> Enum.map(fn user_target ->
          user_channel = Enum.find(user_channels_list, fn user_channel -> user_channel.user_pid == user_target.pid end)
          build_message(user, user_target, user_channel)
        end)
        |> Dispatcher.broadcast(user)

      {:error, :channel_not_found} ->
        :ok
    end
  end

  @spec handle_who_mask(User.t(), String.t(), [String.t()]) :: :ok
  defp handle_who_mask(user, mask, filters) do
    user_pids_sharing_channels_keys =
      UserChannels.get_by_user_pid(user.pid)
      |> Enum.map(& &1.channel_name_key)
      |> UserChannels.get_by_channel_names()
      |> Enum.map(& &1.user_pid)
      |> Enum.uniq()

    users =
      normalize_mask(mask)
      |> Users.get_by_match_mask()
      |> filter_out_invisible_users_for_mask(user_pids_sharing_channels_keys)
      |> maybe_filter_operators(filters)

    users
    |> Enum.map(fn user_target ->
      user_channel_for_mask_target =
        case length(users) == 1 do
          true ->
            UserChannels.get_by_user_pid(user_target.pid)
            |> filter_not_hidden_channel(user_pids_sharing_channels_keys)

          false ->
            nil
        end

      build_message(user, user_target, user_channel_for_mask_target)
    end)
    |> Dispatcher.broadcast(user)
  end

  @spec filter_out_invisible_users_for_channel([User.t()], boolean()) :: [User.t()]
  defp filter_out_invisible_users_for_channel(users, user_shares_channel?) do
    users
    |> Enum.reject(&("i" in &1.modes and !user_shares_channel?))
  end

  @spec filter_out_invisible_users_for_mask([User.t()], [pid()]) :: [User.t()]
  defp filter_out_invisible_users_for_mask(users, user_pids_sharing_channels_keys) do
    users
    |> Enum.reject(&("i" in &1.modes and &1.pid not in user_pids_sharing_channels_keys))
  end

  @spec filter_out_hidden_channel([User.t()], Channel.t(), boolean()) :: [User.t()]
  defp filter_out_hidden_channel(users, channel, user_shares_channel?) do
    if !user_shares_channel? and "s" in channel.modes do
      []
    else
      users
    end
  end

  @spec filter_not_hidden_channel([UserChannel.t()], [pid()]) :: UserChannel.t() | nil
  defp filter_not_hidden_channel(user_channels_list, user_pids_sharing_channels_keys) do
    Enum.find(user_channels_list, fn user_channel ->
      user_shares_channel? = user_channel.user_pid in user_pids_sharing_channels_keys

      user_shares_channel? or
        with {:ok, channel} <- Channels.get_by_name(user_channel.channel_name_key),
             true <- "s" not in channel.modes do
          true
        else
          _ -> false
        end
    end)
  end

  @spec maybe_filter_operators([User.t()], [String.t()]) :: [User.t()]
  defp maybe_filter_operators(users, filters) do
    case filter_operators?(filters) do
      true -> Enum.filter(users, &("o" in &1.modes))
      false -> users
    end
  end

  @spec build_message(User.t(), User.t(), UserChannel.t() | nil) :: Message.t()
  defp build_message(user, user_target, user_channel) do
    # Future: Optimize this function to use channel already fetched,
    # and when not fetched, fetch multiple channels at once.
    user_channel_name =
      with %UserChannel{channel_name_key: channel_name_key} <- user_channel,
           {:ok, channel} <- Channels.get_by_name(channel_name_key) do
        channel.name
      else
        _ -> "*"
      end

    Message.build(%{
      prefix: :server,
      command: :rpl_whoreply,
      params: [
        user_reply(user),
        user_channel_name,
        user_target.ident,
        user_target.hostname,
        Application.get_env(:elixircd, :server)[:hostname],
        user_target.nick,
        user_statuses(user_target, user_channel)
      ],
      trailing: "0 #{user_target.realname}"
    })
  end

  @spec user_statuses(User.t(), UserChannel.t() | nil) :: String.t()
  defp user_statuses(user, user_channel) do
    user_away_status(user) <>
      irc_operator_symbol(user) <>
      channel_operator_symbol(user_channel) <>
      channel_voice_symbol(user_channel)
  end

  @spec user_away_status(User.t()) :: String.t()
  defp user_away_status(%User{} = user), do: if(user.away_message != nil, do: "G", else: "H")

  @spec irc_operator_symbol(User.t()) :: String.t()
  defp irc_operator_symbol(%User{modes: modes}), do: if("o" in modes, do: "*", else: "")

  @spec channel_operator_symbol(UserChannel.t() | nil) :: String.t()
  defp channel_operator_symbol(%UserChannel{modes: modes}), do: if("o" in modes, do: "@", else: "")
  defp channel_operator_symbol(_), do: ""

  @spec channel_voice_symbol(UserChannel.t() | nil) :: String.t()
  defp channel_voice_symbol(%UserChannel{modes: modes}), do: if("v" in modes, do: "+", else: "")
  defp channel_voice_symbol(_), do: ""

  @spec filter_operators?([String.t()]) :: boolean()
  defp filter_operators?([filter | _]) do
    filter
    |> String.downcase()
    |> String.contains?("o")
  end

  defp filter_operators?(_), do: false
end
