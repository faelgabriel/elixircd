defmodule ElixIRCd.Message.MessageBuilder do
  @moduledoc """
  Module for building IRC messages.
  """

  alias ElixIRCd.Core.Server
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message

  @doc """
  Builds an IRC message struct in the form of a user message.
  """
  @spec user_message(String.t(), String.t(), [String.t()], String.t() | nil) :: Message.t()
  def user_message(user_identity, command, params, body \\ nil) do
    %Message{source: user_identity, command: command, params: params, body: body}
  end

  @doc """
  Builds an IRC message struct in the form of a server message.
  """
  @spec server_message(atom() | String.t(), [String.t()], String.t() | nil) :: Message.t()
  def server_message(command, params, body \\ nil)

  # Builds a server message with a numeric reply code.
  def server_message(command, params, body) when is_atom(command) do
    server_name = Server.server_name()
    command_reply = numeric_reply(command)
    %Message{source: server_name, command: command_reply, params: params, body: body}
  end

  # Builds a server message with a raw command string.
  def server_message(command, params, body) do
    server_name = Server.server_name()
    %Message{source: server_name, command: command, params: params, body: body}
  end

  @doc """
  Gets the reply for a user's identity.

  If the user has not registered, the reply is "*".
  Otherwise, the reply is the user's nick.
  """
  @spec get_user_reply(Schemas.User.t()) :: String.t()
  def get_user_reply(%{identity: nil}), do: "*"
  def get_user_reply(%{nick: nick}), do: nick

  # Numeric IRC response codes
  @spec numeric_reply(atom()) :: String.t()
  defp numeric_reply(:rpl_welcome), do: "001"
  defp numeric_reply(:rpl_yourhost), do: "002"
  defp numeric_reply(:rpl_created), do: "003"
  defp numeric_reply(:rpl_whoisuser), do: "311"
  defp numeric_reply(:rpl_whoisserver), do: "312"
  defp numeric_reply(:rpl_whoisidle), do: "317"
  defp numeric_reply(:rpl_endofwhois), do: "318"
  defp numeric_reply(:rpl_whoischannels), do: "319"
  defp numeric_reply(:rpl_topic), do: "332"
  defp numeric_reply(:rpl_notregistered), do: "451"
  defp numeric_reply(:rpl_namreply), do: "353"
  defp numeric_reply(:rpl_endofnames), do: "366"
  defp numeric_reply(:rpl_endofmotd), do: "376"
  defp numeric_reply(:rpl_nouser), do: "401"
  defp numeric_reply(:rpl_cannotsendtochan), do: "404"
  defp numeric_reply(:rpl_cannotjoinchannel), do: "448"
  defp numeric_reply(:rpl_needmoreparams), do: "461"

  defp numeric_reply(:err_nosuchchannel), do: "403"
  defp numeric_reply(:err_unknowncommand), do: "421"
  defp numeric_reply(:err_erroneusnickname), do: "432"
  defp numeric_reply(:err_nicknameinuse), do: "433"
  defp numeric_reply(:err_notonchannel), do: "442"
  defp numeric_reply(:err_notregistered), do: "451"
end
