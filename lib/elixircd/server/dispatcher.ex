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

    if messages == [] or targets == [] do
      :ok
    else
      Enum.each(messages, fn message ->
        message = add_context(message, context)
        broadcast_to_targets(message, targets)
      end)
    end
  end

  @spec broadcast_to_targets(Message.t(), [target()]) :: :ok
  defp broadcast_to_targets(message, targets) do
    Enum.each(targets, fn
      %User{pid: pid} = user ->
        message
        |> filter_tags(user)
        |> send_message(pid)

      pid when is_pid(pid) ->
        send_message(message, pid)
    end)
  end

  @spec send_message(Message.t(), pid()) :: :ok
  defp send_message(message, pid) do
    message
    |> Message.unparse!()
    |> then(&Connection.handle_send(pid, &1))
  end

  @spec add_context(Message.t(), context()) :: Message.t()
  defp add_context(message, %User{modes: modes} = user) do
    message = add_prefix(message, user)

    if "B" in modes do
      %{message | tags: Map.put(message.tags, "bot", nil)}
    else
      message
    end
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

  @spec hostname() :: String.t()
  defp hostname, do: Application.get_env(:elixircd, :server)[:hostname]

  @spec filter_tags(Message.t(), User.t()) :: Message.t()
  defp filter_tags(message, %User{capabilities: caps}) do
    if "MESSAGE-TAGS" in caps do
      message
    else
      %{message | tags: %{}}
    end
  end
end
