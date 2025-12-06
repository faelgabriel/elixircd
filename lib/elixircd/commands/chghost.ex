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
    with :ok <- validate_ident(operator, new_ident),
         :ok <- validate_hostname(operator, new_host) do
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
      {:error, _error} -> :ok
    end
  end

  @spec validate_ident(User.t(), String.t()) :: :ok | {:error, String.t()}
  defp validate_ident(user, ident) do
    max_ident_length = Application.get_env(:elixircd, :user)[:max_ident_length]

    cond do
      String.length(ident) == 0 ->
        %Message{command: :err_invalidusername, params: [user_reply(user)], trailing: "Invalid ident: cannot be empty"}
        |> Dispatcher.broadcast(:server, user)

        {:error, "Invalid ident"}

      String.length(ident) > max_ident_length ->
        %Message{
          command: :err_invalidusername,
          params: [user_reply(user)],
          trailing: "Invalid ident: too long (maximum #{max_ident_length} characters)"
        }
        |> Dispatcher.broadcast(:server, user)

        {:error, "Invalid ident"}

      not valid_ident_chars?(ident) ->
        %Message{
          command: :err_invalidusername,
          params: [user_reply(user)],
          trailing: "Invalid ident: contains invalid characters"
        }
        |> Dispatcher.broadcast(:server, user)

        {:error, "Invalid ident"}

      true ->
        :ok
    end
  end

  @spec validate_hostname(User.t(), String.t()) :: :ok | {:error, String.t()}
  defp validate_hostname(user, hostname) do
    max_hostname_length = 253

    cond do
      String.length(hostname) == 0 ->
        %Message{command: "NOTICE", params: [user_reply(user)], trailing: "Invalid hostname: cannot be empty"}
        |> Dispatcher.broadcast(:server, user)

        {:error, "Invalid hostname"}

      String.length(hostname) > max_hostname_length ->
        %Message{
          command: "NOTICE",
          params: [user_reply(user)],
          trailing: "Invalid hostname: too long (maximum #{max_hostname_length} characters)"
        }
        |> Dispatcher.broadcast(:server, user)

        {:error, "Invalid hostname"}

      not valid_hostname_chars?(hostname) ->
        %Message{
          command: "NOTICE",
          params: [user_reply(user)],
          trailing: "Invalid hostname: contains invalid characters"
        }
        |> Dispatcher.broadcast(:server, user)

        {:error, "Invalid hostname"}

      true ->
        :ok
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
