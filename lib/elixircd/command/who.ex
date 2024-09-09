defmodule ElixIRCd.Command.Who do
  @moduledoc """
  This module defines the WHO command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [channel_name?: 1, get_user_reply: 1, normalize_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "WHO"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WHO", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [get_user_reply(user), "WHO"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
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
    |> Messaging.broadcast(user)
  end

  @spec handle_who_channel(User.t(), String.t(), [String.t()]) :: :ok
  defp handle_who_channel(user, channel_name, filters) do
    Channels.get_by_name(channel_name)
    |> case do
      {:ok, channel} ->
        user_channels = UserChannels.get_by_channel_name(channel_name)
        users = Enum.map(user_channels, & &1.user_port) |> Users.get_by_ports()
        user_shares_channel? = Enum.any?(users, &(&1.port == user.port))

        users
        |> filter_out_hidden_channel(channel, user_shares_channel?)
        |> filter_out_invisible_users_for_channel(user_shares_channel?)
        |> maybe_filter_operators(filters)
        |> Enum.map(fn user_target ->
          user_channel = Enum.find(user_channels, fn user_channel -> user_channel.user_port == user_target.port end)
          build_message(user, user_target, user_channel)
        end)
        |> Messaging.broadcast(user)

      {:error, :channel_not_found} ->
        :ok
    end
  end

  @spec handle_who_mask(User.t(), String.t(), [String.t()]) :: :ok
  defp handle_who_mask(user, mask, filters) do
    user_ports_sharing_channel =
      UserChannels.get_by_user_port(user.port)
      |> Enum.map(& &1.channel_name)
      |> UserChannels.get_by_channel_names()
      |> Enum.map(& &1.user_port)
      |> Enum.uniq()

    users =
      normalize_mask(mask)
      |> Users.get_by_match_mask()
      |> filter_out_invisible_users_for_mask(user_ports_sharing_channel)
      |> maybe_filter_operators(filters)

    users
    |> Enum.map(fn user_target ->
      user_channel =
        case length(users) == 1 do
          true ->
            UserChannels.get_by_user_port(user_target.port)
            |> filter_not_hidden_channel(user_ports_sharing_channel)

          false ->
            nil
        end

      build_message(user, user_target, user_channel)
    end)
    |> Messaging.broadcast(user)
  end

  @spec filter_out_invisible_users_for_channel([User.t()], boolean()) :: [User.t()]
  defp filter_out_invisible_users_for_channel(users, user_shares_channel?) do
    users
    |> Enum.reject(&("i" in &1.modes and !user_shares_channel?))
  end

  @spec filter_out_invisible_users_for_mask([User.t()], [:inet.socket()]) :: [User.t()]
  defp filter_out_invisible_users_for_mask(users, user_ports_sharing_channel) do
    users
    |> Enum.reject(&("i" in &1.modes and &1.port not in user_ports_sharing_channel))
  end

  @spec filter_out_hidden_channel([User.t()], Channel.t(), boolean()) :: [User.t()]
  defp filter_out_hidden_channel(users, channel, user_shares_channel?) do
    if !user_shares_channel? and "s" in channel.modes do
      []
    else
      users
    end
  end

  @spec filter_not_hidden_channel([UserChannel.t()], [:inet.socket()]) :: UserChannel.t() | nil
  defp filter_not_hidden_channel(user_channels, user_ports_sharing_channel) do
    Enum.find(user_channels, fn user_channel ->
      user_shares_channel? = user_channel.user_port in user_ports_sharing_channel

      user_shares_channel? or
        with {:ok, channel} <- Channels.get_by_name(user_channel.channel_name),
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
    user_channel_name =
      case user_channel do
        %UserChannel{channel_name: channel_name} -> channel_name
        nil -> "*"
      end

    Message.build(%{
      prefix: :server,
      command: :rpl_whoreply,
      params: [
        get_user_reply(user),
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
