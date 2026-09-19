defmodule ElixIRCd.Commands.Redact do
  @moduledoc "Implements IRCv3 message redaction with authorization and persistent removal."

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, irc_operator?: 1]

  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.ChatHistory
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User

  @impl true
  def handle(%User{registered: false} = user, _message),
    do: fail(user, "INVALID_TARGET", "*", nil, "Registration required")

  def handle(user, %{params: [target, msgid | _], trailing: reason}) do
    with :ok <- available(user),
         :ok <- valid_reason(reason),
         {:ok, target_info} <- redact_target(user, target),
         {:ok, entry} <- ChatHistory.get_by_msgid(msgid),
         true <- entry.target_key == target_info.key,
         :ok <- authorize(user, entry, target_info),
         _entry <- ChatHistory.redact(entry, DateTime.utc_now()) do
      relay_redaction(user, target_info, msgid, reason)
    else
      {:error, :invalid_target} -> fail(user, "INVALID_TARGET", target, nil, "Invalid redaction target")
      {:error, :history_not_found} -> fail(user, "UNKNOWN_MSGID", target, msgid, "Unknown message ID")
      false -> fail(user, "UNKNOWN_MSGID", target, msgid, "Unknown message ID for target")
      {:error, :forbidden} -> fail(user, "REDACT_FORBIDDEN", target, msgid, "You cannot redact this message")
      {:error, :invalid_reason} -> fail(user, "INVALID_PARAMS", target, msgid, "Invalid redaction reason")
      {:error, :unavailable} -> fail(user, "NEED_CAP", target, msgid, "Message redaction capability is required")
    end
  end

  def handle(user, _message), do: fail(user, "INVALID_PARAMS", "*", nil, "REDACT requires a target and msgid")

  defp available(user) do
    config = Application.fetch_env!(:elixircd, :redaction)
    if config[:enabled] and "draft/message-redaction" in user.capabilities, do: :ok, else: {:error, :unavailable}
  end

  defp valid_reason(nil), do: :ok

  defp valid_reason(reason) do
    max_length = Application.fetch_env!(:elixircd, :redaction)[:max_reason_length]
    if String.length(reason) <= max_length, do: :ok, else: {:error, :invalid_reason}
  end

  defp redact_target(user, target) do
    if channel_name?(target) do
      with {:ok, channel} <- Channels.get_by_name(target),
           true <-
             irc_operator?(user) or match?({:ok, _}, UserChannels.get_by_user_pid_and_channel_name(user.pid, target)) do
        {:ok, %{type: :channel, key: "channel:" <> channel.name_key, name: channel.name}}
      else
        _ -> {:error, :invalid_target}
      end
    else
      History.target_for_request(user, target)
    end
  end

  defp authorize(user, entry, %{type: :channel, name: channel_name}) do
    actor_key = History.identity_key(user)
    own_message? = entry.sender_account_key == actor_key

    # Channel targets are resolved only for current members in the same Mnesia
    # transaction, so membership is an invariant at this point.
    {:ok, membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name)
    channel_operator? = :o in membership.modes

    if own_message? or channel_operator? or irc_operator?(user), do: :ok, else: {:error, :forbidden}
  end

  defp authorize(user, entry, %{type: :direct}) do
    if entry.sender_account_key == History.identity_key(user) or irc_operator?(user),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp relay_redaction(user, %{type: :channel, name: channel_name}, msgid, reason) do
    recipients =
      channel_name
      |> UserChannels.get_by_channel_name()
      |> Enum.map(& &1.user_pid)
      |> Users.get_by_pids()
      |> Enum.filter(&("draft/message-redaction" in &1.capabilities))
      |> maybe_include_actor(user)

    redaction_message(channel_name, msgid, reason)
    |> Dispatcher.broadcast(user, recipients)
  end

  defp relay_redaction(user, %{type: :direct, name: target}, msgid, reason) do
    recipients =
      [
        user
        | case Users.get_by_nick(target) do
            {:ok, target_user} -> [target_user]
            _ -> []
          end
      ]
      |> Enum.filter(&("draft/message-redaction" in &1.capabilities))
      |> Enum.uniq_by(& &1.pid)

    redaction_message(target, msgid, reason)
    |> Dispatcher.broadcast(user, recipients)
  end

  defp redaction_message(target, msgid, nil), do: %Message{command: "REDACT", params: [target, msgid]}

  defp redaction_message(target, msgid, reason),
    do: %Message{command: "REDACT", params: [target, msgid], trailing: reason}

  defp maybe_include_actor(recipients, user) do
    if Enum.any?(recipients, &(&1.pid == user.pid)), do: recipients, else: [user | recipients]
  end

  defp fail(user, code, target, msgid, description) do
    context = if msgid, do: [target, msgid], else: [target]

    %StandardReply{type: :fail, command: "REDACT", code: code, context: context, description: description}
    |> Dispatcher.broadcast(:server, user)
  end
end
