defmodule ElixIRCd.Command.Whois do
  @moduledoc """
  This module defines the WHOIS command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [get_app_version: 0, get_user_identity: 1]

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @command "WHOIS"

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: @command}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, @command],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
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
    |> Messaging.broadcast(user)
  end

  @doc """
  Sends a message to the user with information about the target user.
  """
  @spec whois_message(User.t(), String.t(), User.t(), [String.t()]) :: :ok
  def whois_message(user, target_nick, nil = _target_user, _target_user_channel_names) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchnick,
      params: [user.nick, target_nick],
      trailing: "No such nick"
    })
    |> Messaging.broadcast(user)
  end

  def whois_message(user, _target_nick, target_user, target_user_channel_names) do
    [
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisuser,
        params: [user.nick, target_user.nick, get_user_identity(target_user), target_user.hostname, "*"],
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
        params: [user.nick, target_user.nick, "ElixIRCd", get_app_version()],
        trailing: "Elixir IRC daemon"
      }),
      # TODO: implements idle time
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisidle,
        params: [user.nick, target_user.nick, "0"],
        trailing: "seconds idle, signon time"
      })
    ]
    |> Messaging.broadcast(user)

    # Future: when away is implemented
    # if true do
    #   Message.build(%{
    #     prefix: :server,
    #     command: :rpl_away,
    #     params: [user.nick, target_user.nick],
    #     trailing: "target_user.away_message"
    #   })
    #   |> Messaging.broadcast(user)
    # end

    if "o" in target_user.modes do
      Message.build(%{
        prefix: :server,
        command: :rpl_whoisoperator,
        params: [user.nick, target_user.nick],
        trailing: "is an IRC operator"
      })
      |> Messaging.broadcast(user)
    end

    # Future: when account is implemented
    # if true do
    #   Message.build(%{
    #     prefix: :server,
    #     command: :rpl_whoisaccount,
    #     params: [user.nick, target_user.nick, "target_user.account"],
    #     trailing: "is logged in as target_user.account"
    #   })
    #   |> Messaging.broadcast(user)
    # end
  end

  @spec get_target_user(User.t(), String.t()) :: {User.t() | nil, [String.t()]}
  defp get_target_user(user, target_nick) do
    with {:ok, target_user} <- Users.get_by_nick(target_nick),
         target_user_channel_names <- UserChannels.get_by_user_port(target_user.port) |> Enum.map(& &1.channel_name),
         true <- target_user_visible?(user, target_user, target_user_channel_names) do
      {target_user, target_user_channel_names}
    else
      _ -> {nil, []}
    end
  end

  @spec target_user_visible?(User.t(), User.t(), [String.t()]) :: boolean()
  defp target_user_visible?(user, target_user, target_user_channel_names) do
    if "i" in target_user.modes do
      user_channel_names = UserChannels.get_by_user_port(user.port) |> Enum.map(& &1.channel_name)
      Enum.any?(user_channel_names, &Enum.member?(target_user_channel_names, &1))
    else
      true
    end
  end
end
