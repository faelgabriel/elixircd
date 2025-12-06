defmodule ElixIRCd.Commands.Chghost do
  @moduledoc """
  This module defines the CHGHOST command.

  CHGHOST allows IRC operators to forcefully change a user's ident and hostname.
  This is an operator-only command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "CHGHOST"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "CHGHOST", params: params}) when length(params) < 3 do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "CHGHOST"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "CHGHOST", params: [target_nick, new_ident, new_host]}) do
    with {:operator, true} <- {:operator, irc_operator?(user)},
         {:ok, target_user} <- Users.get_by_nick(target_nick) do
      change_host(user, target_user, new_ident, new_host)
    else
      {:operator, false} ->
        %Message{
          command: :err_noprivileges,
          params: [user_reply(user)],
          trailing: "Permission denied - You're not an IRC operator"
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :user_not_found} ->
        %Message{command: :err_nosuchnick, params: [user_reply(user), target_nick], trailing: "No such nick/channel"}
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec change_host(User.t(), User.t(), String.t(), String.t()) :: :ok
  defp change_host(operator, target_user, new_ident, new_host) do
    with :ok <- validate_ident(new_ident),
         :ok <- validate_hostname(new_host) do
      old_ident = target_user.ident
      old_host = target_user.hostname

      updated_user = Users.update(target_user, %{ident: new_ident, hostname: new_host})

      notify_chghost(updated_user, old_ident, old_host, new_ident, new_host)

      %Message{
        command: "NOTICE",
        params: [operator.nick],
        trailing: "Changed host for #{target_user.nick} from #{old_ident}@#{old_host} to #{new_ident}@#{new_host}"
      }
      |> Dispatcher.broadcast(:server, operator)
    else
      {:error, :ident_empty} ->
        %Message{
          command: :err_invalidusername,
          params: [user_reply(operator)],
          trailing: "Invalid ident: cannot be empty"
        }
        |> Dispatcher.broadcast(:server, operator)

      {:error, :ident_too_long} ->
        max_ident_length = Application.get_env(:elixircd, :user)[:max_ident_length]

        %Message{
          command: :err_invalidusername,
          params: [user_reply(operator)],
          trailing: "Invalid ident: too long (maximum #{max_ident_length} characters)"
        }
        |> Dispatcher.broadcast(:server, operator)

      {:error, :ident_invalid_chars} ->
        %Message{
          command: :err_invalidusername,
          params: [user_reply(operator)],
          trailing: "Invalid ident: contains invalid characters"
        }
        |> Dispatcher.broadcast(:server, operator)

      {:error, :hostname_empty} ->
        %Message{command: "NOTICE", params: [user_reply(operator)], trailing: "Invalid hostname: cannot be empty"}
        |> Dispatcher.broadcast(:server, operator)

      {:error, :hostname_too_long} ->
        %Message{
          command: "NOTICE",
          params: [user_reply(operator)],
          trailing: "Invalid hostname: too long (maximum 253 characters)"
        }
        |> Dispatcher.broadcast(:server, operator)

      {:error, :hostname_invalid_chars} ->
        %Message{
          command: "NOTICE",
          params: [user_reply(operator)],
          trailing: "Invalid hostname: contains invalid characters"
        }
        |> Dispatcher.broadcast(:server, operator)
    end
  end

  @spec validate_ident(String.t()) :: :ok | {:error, :ident_empty | :ident_too_long | :ident_invalid_chars}
  defp validate_ident(ident) do
    max_ident_length = Application.get_env(:elixircd, :user)[:max_ident_length]

    cond do
      String.length(ident) == 0 -> {:error, :ident_empty}
      String.length(ident) > max_ident_length -> {:error, :ident_too_long}
      not valid_ident_chars?(ident) -> {:error, :ident_invalid_chars}
      true -> :ok
    end
  end

  @spec validate_hostname(String.t()) :: :ok | {:error, :hostname_empty | :hostname_too_long | :hostname_invalid_chars}
  defp validate_hostname(hostname) do
    max_hostname_length = 253

    cond do
      String.length(hostname) == 0 -> {:error, :hostname_empty}
      String.length(hostname) > max_hostname_length -> {:error, :hostname_too_long}
      not valid_hostname_chars?(hostname) -> {:error, :hostname_invalid_chars}
      true -> :ok
    end
  end

  @spec valid_ident_chars?(String.t()) :: boolean()
  defp valid_ident_chars?(ident) do
    # Ident can contain alphanumeric characters, hyphens, underscores, and tildes
    String.match?(ident, ~r/^[a-zA-Z0-9\-_~]+$/)
  end

  @spec valid_hostname_chars?(String.t()) :: boolean()
  defp valid_hostname_chars?(hostname) do
    # Hostname can contain alphanumeric characters, hyphens, periods, and colons (for IPv6)
    String.match?(hostname, ~r/^[a-zA-Z0-9\-.:]+$/)
  end

  @spec notify_chghost(User.t(), String.t(), String.t(), String.t(), String.t()) :: :ok
  defp notify_chghost(user, old_ident, old_host, new_ident, new_host) do
    chghost_supported = Application.get_env(:elixircd, :capabilities)[:chghost] || false

    if chghost_supported do
      watchers = Users.get_in_shared_channels_with_capability(user, "CHGHOST", true)

      if watchers != [] do
        %Message{command: "CHGHOST", params: [new_ident, new_host]}
        |> Dispatcher.broadcast(%{user | ident: old_ident, hostname: old_host}, watchers)
      end
    end

    :ok
  end
end
