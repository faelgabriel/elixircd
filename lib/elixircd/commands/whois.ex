defmodule ElixIRCd.Commands.Whois do
  @moduledoc """
  This module defines the WHOIS command.
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
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply(user), @command],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: [target_nick | _rest]}) do
    {target_user, target_user_channel_names} = get_target_user(user, target_nick)

    whois_message(user, target_nick, target_user, target_user_channel_names)

    Message.build(%{
      prefix: :server,
      command: :rpl_endofwhois,
      params: [user.nick, target_nick],
      trailing: "End of /WHOIS list."
    })
    |> Dispatcher.broadcast(user)
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(User.t(), String.t(), User.t() | nil, [String.t()]) :: :ok
  def whois_message(user, target_nick, nil = _target_user, _target_user_channel_names) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchnick,
      params: [user.nick, target_nick],
      trailing: "No such nick"
    })
    |> Dispatcher.broadcast(user)
  end

  def whois_message(user, _target_nick, target_user, target_user_channel_names) when target_user != nil do
    idle_seconds = (:erlang.system_time(:second) - target_user.last_activity) |> to_string()
    signon_time = target_user.registered_at |> DateTime.to_unix()

    [
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisuser,
        params: [user.nick, target_user.nick, target_user.ident, target_user.hostname, "*"],
        trailing: target_user.realname
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_whoischannels,
        params: [user.nick, target_user.nick],
        trailing: target_user_channel_names |> Enum.join(" ")
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisserver,
        params: [user.nick, target_user.nick, "ElixIRCd", Application.spec(:elixircd, :vsn)],
        trailing: "Elixir IRC daemon"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisidle,
        params: [user.nick, target_user.nick, idle_seconds, signon_time],
        trailing: "seconds idle, signon time"
      })
    ]
    |> Dispatcher.broadcast(user)

    if target_user.away_message != nil do
      Message.build(%{
        prefix: :server,
        command: :rpl_away,
        params: [user.nick, target_user.nick],
        trailing: target_user.away_message
      })
      |> Dispatcher.broadcast(user)
    end

    if "o" in target_user.modes do
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisoperator,
        params: [user.nick, target_user.nick],
        trailing: "is an IRC operator"
      })
      |> Dispatcher.broadcast(user)
    end

    # Feature: account implementation
    # if true do
    #   Message.build(%{
    #     prefix: :server,
    #     command: :rpl_whoisaccount,
    #     params: [user.nick, target_user.nick, "target_user.account"],
    #     trailing: "is logged in as target_user.account"
    #   })
    #   |> Dispatcher.broadcast(user)
    # end
  end

  @spec get_target_user(User.t(), String.t()) :: {User.t() | nil, [String.t()]}
  defp get_target_user(user, target_nick) do
    with {:ok, target_user} <- Users.get_by_nick(target_nick),
         user_channel_names <- UserChannels.get_by_user_pid(user.pid) |> Enum.map(& &1.channel_name),
         target_user_channel_names <- UserChannels.get_by_user_pid(target_user.pid) |> Enum.map(& &1.channel_name),
         true <- target_user_visible?(user_channel_names, target_user, target_user_channel_names) do
      {target_user, filter_out_secret_channels(user_channel_names, target_user_channel_names)}
    else
      _ -> {nil, []}
    end
  end

  @spec target_user_visible?([String.t()], User.t(), [String.t()]) :: boolean()
  defp target_user_visible?(user_channel_names, target_user, target_user_channel_names) do
    if "i" in target_user.modes do
      Enum.any?(user_channel_names, &Enum.member?(target_user_channel_names, &1))
    else
      true
    end
  end

  @spec filter_out_secret_channels([String.t()], [String.t()]) :: [String.t()]
  defp filter_out_secret_channels(user_channel_names, target_user_channel_names) do
    Enum.reject(target_user_channel_names, fn channel_name ->
      with {:ok, channel} <- Channels.get_by_name(channel_name),
           true <- "s" in channel.modes do
        not Enum.member?(user_channel_names, channel_name)
      else
        _ -> false
      end
    end)
  end
end
