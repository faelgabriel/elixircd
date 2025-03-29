defmodule ElixIRCd.Utils.Nickserv do
  @moduledoc """
  Utility functions for NickServ service.
  """

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @doc """
  Sends a NickServ notice to a user.
  """
  @spec send_notice(User.t(), String.t()) :: :ok
  def send_notice(user, message) do
    Message.build(%{
      prefix: "NickServ!service@#{Application.get_env(:elixircd, :server)[:hostname]}",
      command: "NOTICE",
      params: [user_reply(user)],
      trailing: message
    })
    |> Dispatcher.broadcast(user)
  end

  @doc """
  Formats the email required format for a NickServ command.
  """
  @spec email_required_format(boolean()) :: String.t()
  def email_required_format(email_required?) do
    if email_required?, do: "<email-address>", else: "[email-address]"
  end
end
