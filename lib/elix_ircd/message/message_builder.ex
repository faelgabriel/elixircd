defmodule ElixIRCd.Message.MessageBuilder do
  @moduledoc """
  Module for building IRC messages.
  """

  alias ElixIRCd.Core.Server
  alias ElixIRCd.Message.Message

  @doc """
  Builds an IRC message struct in the form of a user message.
  """
  @spec user_message(String.t(), String.t(), [String.t()], String.t() | nil) :: Message.t()
  def user_message(user_identity, command, params, body \\ nil) do
    %Message{prefix: user_identity, command: command, params: params, body: body}
  end

  @doc """
  Builds an IRC message struct in the form of a server message.
  """
  @spec server_message(atom(), [String.t()], String.t() | nil) :: Message.t()
  def server_message(command, params, body \\ nil) when is_atom(command) do
    server_name = Server.server_name()
    command_reply = numeric_reply(command)
    %Message{prefix: server_name, command: command_reply, params: params, body: body}
  end

  # Numeric IRC response codes
  @spec numeric_reply(atom()) :: String.t()
  defp numeric_reply(:rpl_welcome), do: "001"
  defp numeric_reply(:rpl_yourhost), do: "002"
  defp numeric_reply(:rpl_created), do: "003"
  defp numeric_reply(:rpl_myinfo), do: "004"
  defp numeric_reply(:rpl_luserclient), do: "251"
  defp numeric_reply(:rpl_luserop), do: "252"
  defp numeric_reply(:rpl_luserunknown), do: "253"
  defp numeric_reply(:rpl_luserchannels), do: "254"
  defp numeric_reply(:rpl_luserme), do: "255"
  defp numeric_reply(:rpl_away), do: "301"
  defp numeric_reply(:rpl_unaway), do: "305"
  defp numeric_reply(:rpl_nowaway), do: "306"
  defp numeric_reply(:rpl_whoisuser), do: "311"
  defp numeric_reply(:rpl_whoisserver), do: "312"
  defp numeric_reply(:rpl_whoisoperator), do: "313"
  defp numeric_reply(:rpl_whoisidle), do: "317"
  defp numeric_reply(:rpl_endofwhois), do: "318"
  defp numeric_reply(:rpl_whoischannels), do: "319"
  defp numeric_reply(:rpl_whoreply), do: "352"
  defp numeric_reply(:rpl_endofwho), do: "315"
  defp numeric_reply(:rpl_liststart), do: "321"
  defp numeric_reply(:rpl_list), do: "322"
  defp numeric_reply(:rpl_listend), do: "323"
  defp numeric_reply(:rpl_channelmodeis), do: "324"
  defp numeric_reply(:rpl_notopic), do: "331"
  defp numeric_reply(:rpl_topic), do: "332"
  defp numeric_reply(:rpl_namreply), do: "353"
  defp numeric_reply(:rpl_endofnames), do: "366"
  defp numeric_reply(:rpl_motdstart), do: "375"
  defp numeric_reply(:rpl_motd), do: "372"
  defp numeric_reply(:rpl_endofmotd), do: "376"
  defp numeric_reply(:rpl_youreoper), do: "381"
  defp numeric_reply(:rpl_time), do: "391"
  defp numeric_reply(:rpl_usersstart), do: "392"
  defp numeric_reply(:rpl_users), do: "393"
  defp numeric_reply(:rpl_endofusers), do: "394"
  defp numeric_reply(:rpl_nousers), do: "395"
end
