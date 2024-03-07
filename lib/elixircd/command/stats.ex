defmodule ElixIRCd.Command.Stats do
  @moduledoc """
  This module defines the STATS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "STATS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "STATS", params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "STATS"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "STATS", params: [_query_flag | _rest]}) do
    # Scenario: Client queries for specific statistics with a query flag
    # Depending on the query flag, collect and respond with the requested statistics.
    # Example flags and their associated responses:
    # - 'l': Return information about server connections (RPL_STATSLINKINFO).
    # - 'u': Server uptime (RPL_STATSUPTIME).
    # - 'm': Usage counts for each of commands (RPL_STATSCOMMANDS).
    # - 'o': List of operator privileges (RPL_STATSOLINE).
    # Each flag requires the server to respond with the appropriate RPL_* numeric replies
    # and potentially ends with RPL_ENDOFSTATS (219) to indicate the end of the STATS report.
    # Note: Ensure to check if the user has the necessary privileges to view the requested statistics,
    # especially for sensitive information. Respond with ERR_NOPRIVILEGES (481) if not authorized.
    :ok
  end
end
