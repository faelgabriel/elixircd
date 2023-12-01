defmodule ElixIRCd.Core.Handshake do
  @moduledoc """
  Module for handling IRC handshake.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder

  require Logger

  @doc """
  Handles the user handshake.
  """
  @spec handshake(Schemas.User.t()) :: :ok
  def handshake(user) when user.nick != nil and user.username != nil and user.realname != nil do
    {:ok, user} = handle_lookup_hostname(user)
    :ok = handle_motd(user)
    :ok
  end

  def handshake(_user), do: :ok

  @spec handle_lookup_hostname(Schemas.User.t()) :: {:ok, Schemas.User.t()} | {:error, Changeset.t()}
  defp handle_lookup_hostname(user) do
    {:ok, {ip, _port}} = :inet.peername(user.socket)

    hostname =
      case :inet.gethostbyaddr(ip) do
        {:ok, {:hostent, hostname, _, _, _, _}} ->
          hostname |> to_string()

        {:error, _error} ->
          Logger.info("Could not resolve hostname for #{ip}. Using IP instead.")
          Enum.join(Tuple.to_list(ip), ".")
      end

    identity = "#{user.nick}!#{String.slice(user.username, 0..7)}@#{hostname}"
    Contexts.User.update(user, %{hostname: hostname, identity: identity})
  end

  @spec handle_motd(Schemas.User.t()) :: :ok
  defp handle_motd(user) do
    MessageBuilder.server_message(:rpl_welcome, [user.nick], "Welcome to the IRC network.")
    |> Messaging.send_message(user)

    MessageBuilder.server_message(:rpl_yourhost, [user.nick], "Your host is ElixIRCd, running version 0.1.0.")
    |> Messaging.send_message(user)

    MessageBuilder.server_message(:rpl_created, [user.nick], "ElixIRCd 0.1.0 +i +int")
    |> Messaging.send_message(user)

    MessageBuilder.server_message(:rpl_endofmotd, [user.nick], "End of MOTD command")
    |> Messaging.send_message(user)

    :ok
  end
end
