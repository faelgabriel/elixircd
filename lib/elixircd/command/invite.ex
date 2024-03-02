defmodule ElixIRCd.Command.Invite do
  @moduledoc """
  This module defines the INVITE command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "INVITE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "INVITE", params: params}) when length(params) <= 1 do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "INVITE"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "INVITE", params: [_target_nick, _channel_name | _rest]}) do
    # Scenarios to handle when both target nickname and channel name are provided:
    # 1. Target user does not exist: ERR_NOSUCHNICK (401)
    # 2. Inviting user not on the channel: ERR_NOTONCHANNEL (442)
    # 3. Target user already on the channel: ERR_USERONCHANNEL (443)
    # 4. Inviting user lacks privileges to invite: ERR_CHANOPRIVSNEEDED (482)
    # 5. Successful invite: Send RPL_INVITING (341) and handle possible RPL_AWAY (301)
    # Each condition leads to a specific IRC numeric response or action.
    :ok
  end
end
