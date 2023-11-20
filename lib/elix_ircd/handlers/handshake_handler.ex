defmodule ElixIRCd.Handlers.HandshakeHandler do
  @moduledoc """
  Module for handling IRC handshake.
  """

  alias Ecto.Changeset
  alias ElixIRCd.Contexts
  alias ElixIRCd.Handlers.MessageHandler
  alias ElixIRCd.Schemas

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
    MessageHandler.send_message(user, :server, "001 #{user.nick} Welcome to the IRC network.")
    MessageHandler.send_message(user, :server, "002 #{user.nick} Your host is ElixIRCd, running version 0.1.0.")
    MessageHandler.send_message(user, :server, "003 #{user.nick} ElixIRCd 0.1.0 +i +int")
    MessageHandler.send_message(user, :server, "376 #{user.nick} :End of MOTD command")
    # Future:: MessageHandler.send_message(user, :server, "422 :MOTD File is missing")
    :ok
  end
end
