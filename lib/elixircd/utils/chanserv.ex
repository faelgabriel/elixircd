defmodule ElixIRCd.Utils.Chanserv do
  @moduledoc """
  Utility functions for ChanServ service.
  """

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @doc """
  Sends ChanServ notices to a user.
  """
  @spec notify(User.t(), String.t() | [String.t()]) :: :ok
  def notify(user, message) when is_binary(message) do
    send_notice(user, message)
  end

  def notify(user, messages) when is_list(messages) do
    Enum.each(messages, fn message -> send_notice(user, message) end)
    :ok
  end

  @spec send_notice(User.t(), String.t()) :: :ok
  defp send_notice(user, message) do
    Message.build(%{
      prefix: "ChanServ!service@#{Application.get_env(:elixircd, :server)[:hostname]}",
      command: "NOTICE",
      params: [user_reply(user)],
      trailing: message
    })
    |> Dispatcher.broadcast(user)
  end
end
