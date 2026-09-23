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
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Server.S2S.Action
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Monitor

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

  def handle(user, %{command: "CHGHOST", params: [target_nick, new_ident, new_host], tags: tags}) do
    with {:operator, true} <- {:operator, irc_operator?(user)} do
      response_context = Action.response_context(user, tags, "CHGHOST target server is unavailable")

      case remote_target_context(target_nick) do
        {:ok, manager, runtime, target_uid, target_user, target_sid} ->
          remote_change_host(
            user,
            manager,
            runtime,
            target_uid,
            target_user,
            target_sid,
            new_ident,
            new_host,
            response_context
          )

        :local ->
          case Users.get_by_nick(target_nick) do
            {:ok, target_user} -> change_host(user, target_user, new_ident, new_host)
            {:error, :user_not_found} -> target_not_found(user, target_nick)
          end
      end
    else
      {:operator, false} ->
        %Message{
          command: :err_noprivileges,
          params: [user_reply(user)],
          trailing: "Permission denied - You're not an IRC operator"
        }
        |> Dispatcher.broadcast(:server, user)
    end
  end

  defp remote_change_host(
         operator,
         manager,
         runtime,
         target_uid,
         target_user,
         target_sid,
         new_ident,
         new_host,
         response_context
       ) do
    with :ok <- validate_ident(new_ident),
         :ok <- validate_hostname(new_host) do
      guards = %{
        "actor_uid" => operator.uid,
        "actor_user_rev" => operator.owner_rev,
        "actor_join_id" => nil,
        "target_user_rev" => target_user.owner_rev,
        "target_join_id" => nil,
        "channel" => nil,
        "policy_epoch" => runtime.policy.epoch,
        "policy_revision" => runtime.policy.revision
      }

      requests = [
        %{
          method: "user_action",
          args: %{
            "action" => "host",
            "target_uid" => target_uid,
            "value" => %{"displayhost" => new_host},
            "reason" => "CHGHOST"
          },
          guards: guards
        },
        %{
          method: "user_action",
          args: %{
            "action" => "ident",
            "target_uid" => target_uid,
            "value" => %{"ident" => new_ident},
            "reason" => "CHGHOST"
          },
          guards: guards
        }
      ]

      response_context =
        Action.success_context(response_context, %{
          "command" => "NOTICE",
          "params" => [operator.nick],
          "trailing" =>
            "Changed host for #{target_user.nick} from #{target_user.ident}@#{target_user.hostname} to " <>
              "#{new_ident}@#{new_host}"
        })

      result = Action.enqueue_sequence(manager, target_sid, operator, requests, response_context)

      case result do
        :queued ->
          ResponseContext.defer_response(operator)
          :ok

        {:error, _reason} ->
          send_remote_error(operator, "CHGHOST target server is unavailable")
      end
    else
      {:error, :ident_empty} ->
        invalid_ident(operator, "Invalid ident: cannot be empty")

      {:error, :ident_too_long} ->
        invalid_ident(operator, "Invalid ident: too long")

      {:error, :ident_invalid_chars} ->
        invalid_ident(operator, "Invalid ident: contains invalid characters")

      {:error, :hostname_empty} ->
        invalid_hostname(operator, target_user, "Invalid hostname: cannot be empty")

      {:error, :hostname_too_long} ->
        invalid_hostname(operator, target_user, "Invalid hostname: too long (maximum 253 characters)")

      {:error, :hostname_invalid_chars} ->
        invalid_hostname(operator, target_user, "Invalid hostname: contains invalid characters")
    end
  end

  defp remote_target_context(target_nick) do
    with manager when is_pid(manager) <- Process.whereis(Manager),
         {:ok, runtime} <- View.runtime(manager),
         {:ok, target_uid, target_user, target_sid} <- Action.remote_target(runtime, target_nick) do
      {:ok, manager, runtime, target_uid, target_user, target_sid}
    else
      :local -> :local
      {:error, :not_found} -> :local
      _ -> :local
    end
  end

  defp target_not_found(user, target_nick) do
    %Message{command: :err_nosuchnick, params: [user_reply(user), target_nick], trailing: "No such nick/channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp invalid_ident(user, description) do
    %Message{command: :err_invalidusername, params: [user_reply(user)], trailing: description}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_remote_error(user, message) do
    %Message{command: "NOTICE", params: [user_reply(user)], trailing: message}
    |> Dispatcher.broadcast(:server, user)
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
        max_ident_length = Application.fetch_env!(:elixircd, :user)[:max_ident_length]

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
        invalid_hostname(operator, target_user, "Invalid hostname: cannot be empty")

      {:error, :hostname_too_long} ->
        invalid_hostname(operator, target_user, "Invalid hostname: too long (maximum 253 characters)")

      {:error, :hostname_invalid_chars} ->
        invalid_hostname(operator, target_user, "Invalid hostname: contains invalid characters")
    end
  end

  @spec invalid_hostname(User.t(), User.t(), String.t()) :: :ok
  defp invalid_hostname(operator, target_user, description) do
    reply = %StandardReply{
      type: :fail,
      command: "CHGHOST",
      code: "INVALID_HOSTNAME",
      context: [target_user.nick],
      description: description
    }

    fallback = %Message{command: "NOTICE", params: [user_reply(operator)], trailing: description}

    Dispatcher.broadcast_standard_reply(reply, :server, operator, fallback)
  end

  @spec validate_ident(String.t()) :: :ok | {:error, :ident_empty | :ident_too_long | :ident_invalid_chars}
  defp validate_ident(ident) do
    max_ident_length = Application.fetch_env!(:elixircd, :user)[:max_ident_length]

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
    chghost_supported = Application.fetch_env!(:elixircd, :capabilities)[:chghost]

    if chghost_supported do
      watchers = Monitor.notification_watchers(user, "chghost", true)

      if watchers != [] do
        %Message{command: "CHGHOST", params: [new_ident, new_host]}
        |> Dispatcher.broadcast(%{user | ident: old_ident, hostname: old_host}, watchers)
      end
    end

    :ok
  end
end
