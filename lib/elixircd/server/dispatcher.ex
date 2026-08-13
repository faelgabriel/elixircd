defmodule ElixIRCd.Server.Dispatcher do
  @moduledoc """
  Module for dispatching messages to users.
  """

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Tables.User

  @type target :: pid() | User.t()
  @type context :: :server | :chanserv | :nickserv | User.t() | nil

  @doc """
  Broadcasts messages with context to the given targets.
  """
  @spec broadcast(Message.t() | [Message.t()], context(), target() | [target()]) :: :ok
  def broadcast(messages, context, targets) do
    messages = List.wrap(messages)
    targets = List.wrap(targets)
    source_user = source_user_from_context(context)

    if messages == [] or targets == [] do
      :ok
    else
      any_msgid_cap? =
        Enum.any?(targets, fn
          %User{capabilities: caps} -> "msgid" in caps and recipient_supports_message_tags?(MapSet.new(caps))
          _ -> false
        end)

      Enum.each(messages, fn message ->
        message =
          message
          |> add_context(context)
          |> maybe_put_base_msgid(any_msgid_cap?)

        broadcast_to_targets(message, targets, source_user)
      end)
    end
  end

  @doc """
  Broadcasts user-originated messages and echoes them back to the sender when the
  `echo-message` capability is enabled for that user.
  """
  @spec broadcast_with_echo(Message.t() | [Message.t()], User.t(), target() | [target()]) :: :ok
  def broadcast_with_echo(messages, %User{} = sender, targets) do
    all_targets =
      targets
      |> List.wrap()
      |> maybe_include_echo_target(sender)

    broadcast(messages, sender, all_targets)
  end

  @spec maybe_include_echo_target([target()], User.t()) :: [target()]
  defp maybe_include_echo_target(targets, sender) do
    targets =
      if echo_message_enabled?(sender) do
        [sender | targets]
      else
        targets
      end

    Enum.uniq_by(targets, &target_pid/1)
  end

  @spec echo_message_enabled?(User.t()) :: boolean()
  defp echo_message_enabled?(%User{capabilities: capabilities}) do
    echo_message_supported = Application.get_env(:elixircd, :capabilities)[:echo_message] || false
    echo_message_supported and "echo-message" in capabilities
  end

  @spec target_pid(target()) :: pid()
  defp target_pid(%User{pid: pid}), do: pid
  defp target_pid(pid) when is_pid(pid), do: pid

  @spec source_user_from_context(context()) :: User.t() | nil
  defp source_user_from_context(%User{} = user), do: user
  defp source_user_from_context(_context), do: nil

  @spec broadcast_to_targets(Message.t(), [target()], User.t() | nil) :: :ok
  defp broadcast_to_targets(message, targets, source_user) do
    Enum.each(targets, fn
      %User{pid: pid} = user ->
        maybe_send_to_user(message, user, pid)

      pid when is_pid(pid) ->
        case source_user do
          %User{pid: ^pid} = user ->
            maybe_send_to_user(message, user, pid)

          _other ->
            send_message(message, pid)
        end
    end)
  end

  @spec maybe_send_to_user(Message.t(), User.t(), pid()) :: :ok
  defp maybe_send_to_user(message, user, pid) do
    message
    |> filter_tags(user)
    |> send_message(pid)
  end

  @spec send_message(Message.t(), pid()) :: :ok
  defp send_message(message, pid) do
    message
    |> Message.unparse!()
    |> then(&Connection.handle_send(pid, &1))
  end

  @spec add_context(Message.t(), context()) :: Message.t()
  defp add_context(message, %User{modes: modes} = user) do
    message =
      message
      |> sanitize_client_message_tags(user)
      |> add_prefix(user)
      |> maybe_put_bot_tag(modes)
      |> maybe_put_account_tag(user)

    message
  end

  defp add_context(message, context) do
    add_prefix(message, context)
  end

  @spec add_prefix(Message.t(), context() | String.t()) :: Message.t()
  defp add_prefix(%Message{} = message, %User{} = user), do: %{message | prefix: user_mask(user)}
  defp add_prefix(%Message{} = message, :server), do: %{message | prefix: hostname()}
  defp add_prefix(%Message{} = message, :chanserv), do: %{message | prefix: "ChanServ!service@#{hostname()}"}
  defp add_prefix(%Message{} = message, :nickserv), do: %{message | prefix: "NickServ!service@#{hostname()}"}
  defp add_prefix(%Message{} = message, nil), do: message

  @spec sanitize_client_message_tags(Message.t(), User.t()) :: Message.t()
  defp sanitize_client_message_tags(%Message{tags: tags} = message, %User{capabilities: capabilities}) do
    sanitized_tags =
      if "message-tags" in capabilities do
        relayable_client_tags(tags)
      else
        %{}
      end

    %{message | tags: sanitized_tags}
  end

  @spec maybe_put_bot_tag(Message.t(), [String.t()]) :: Message.t()
  defp maybe_put_bot_tag(%Message{} = message, modes) do
    if "B" in modes do
      %{message | tags: Map.put(message.tags, "bot", nil)}
    else
      message
    end
  end

  @spec maybe_put_account_tag(Message.t(), User.t()) :: Message.t()
  defp maybe_put_account_tag(%Message{} = message, %User{identified_as: nil}), do: message

  defp maybe_put_account_tag(%Message{} = message, %User{identified_as: account}) do
    account_tag_supported = Application.get_env(:elixircd, :capabilities)[:account_tag] || false

    if account_tag_supported do
      %{message | tags: Map.put(message.tags, "account", account)}
    else
      message
    end
  end

  @spec maybe_put_base_msgid(Message.t(), boolean()) :: Message.t()
  defp maybe_put_base_msgid(%Message{} = message, false), do: message

  defp maybe_put_base_msgid(%Message{tags: tags} = message, true) do
    msgid_supported = Application.get_env(:elixircd, :capabilities)[:msgid] || false

    if msgid_supported and not Map.has_key?(tags, "msgid") do
      msgid =
        System.unique_integer([:positive, :monotonic])
        |> Integer.to_string(36)

      %{message | tags: Map.put(tags, "msgid", msgid)}
    else
      message
    end
  end

  @spec hostname() :: String.t()
  defp hostname, do: Application.get_env(:elixircd, :server)[:hostname]

  @spec filter_tags(Message.t(), User.t()) :: Message.t()
  defp filter_tags(message, %User{capabilities: caps}) do
    capabilities = MapSet.new(caps)

    if recipient_supports_message_tags?(capabilities) do
      tags =
        message.tags
        |> maybe_put_server_time_tag(capabilities)
        |> maybe_filter_msgid_tag(capabilities)
        |> maybe_filter_account_tag(capabilities)

      %{message | tags: tags}
    else
      %{message | tags: %{}}
    end
  end

  @spec recipient_supports_message_tags?(MapSet.t(String.t())) :: boolean()
  defp recipient_supports_message_tags?(capabilities) do
    Enum.any?(["message-tags", "account-tag", "server-time", "msgid"], &MapSet.member?(capabilities, &1))
  end

  @spec maybe_put_server_time_tag(Message.tags(), MapSet.t()) :: Message.tags()
  defp maybe_put_server_time_tag(tags, capabilities) do
    server_time_supported = Application.get_env(:elixircd, :capabilities)[:server_time] || false

    if server_time_supported and MapSet.member?(capabilities, "server-time") and not Map.has_key?(tags, "time") do
      time =
        DateTime.utc_now()
        |> DateTime.truncate(:millisecond)
        |> DateTime.to_iso8601()

      Map.put(tags, "time", time)
    else
      tags
    end
  end

  @spec maybe_filter_msgid_tag(Message.tags(), MapSet.t()) :: Message.tags()
  defp maybe_filter_msgid_tag(tags, capabilities) do
    msgid_supported = Application.get_env(:elixircd, :capabilities)[:msgid] || false

    cond do
      not msgid_supported -> Map.delete(tags, "msgid")
      not MapSet.member?(capabilities, "msgid") -> Map.delete(tags, "msgid")
      true -> tags
    end
  end

  @spec maybe_filter_account_tag(Message.tags(), MapSet.t()) :: Message.tags()
  defp maybe_filter_account_tag(tags, capabilities) do
    account_tag_supported = Application.get_env(:elixircd, :capabilities)[:account_tag] || false

    cond do
      not account_tag_supported -> Map.delete(tags, "account")
      not MapSet.member?(capabilities, "account-tag") -> Map.delete(tags, "account")
      true -> tags
    end
  end

  @spec relayable_client_tags(Message.tags()) :: Message.tags()
  defp relayable_client_tags(tags) do
    Map.filter(tags, fn {tag_name, _value} -> String.starts_with?(tag_name, "+") end)
  end
end
