defmodule ElixIRCd.Commands.Setname do
  @moduledoc """
  This module defines the SETNAME command.

  SETNAME allows users to change their real name (GECOS) during an active session.
  The server must enable `setname`; clients need not negotiate it to use the command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "SETNAME"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "SETNAME", params: [realname | _]} = message) do
    handle(user, %{message | params: [], trailing: realname})
  end

  def handle(user, %{command: "SETNAME", trailing: nil}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "SETNAME"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "SETNAME", trailing: new_realname}) do
    setname_supported = Application.get_env(:elixircd, :capabilities)[:setname] || false

    with {:capability, true} <- {:capability, setname_supported},
         :ok <- validate_realname(new_realname),
         {:changed, true} <- {:changed, new_realname != user.realname} do
      change_realname(user, new_realname)
    else
      {:capability, false} ->
        %Message{command: :err_unknowncommand, params: [user_reply(user), "SETNAME"], trailing: "Unknown command"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :realname_empty} ->
        reply = %StandardReply{
          type: :fail,
          command: "SETNAME",
          code: "INVALID_REALNAME",
          description: "Realname cannot be empty"
        }

        Dispatcher.broadcast(reply, :server, user)

      {:error, :realname_too_long} ->
        max_realname_length = Application.get_env(:elixircd, :user)[:max_realname_length]

        reply = %StandardReply{
          type: :fail,
          command: "SETNAME",
          code: "INVALID_REALNAME",
          description: "Realname too long (maximum #{max_realname_length} characters)"
        }

        Dispatcher.broadcast(reply, :server, user)

      {:changed, false} ->
        notify_setname(user, new_realname)
    end
  end

  @spec validate_realname(String.t()) :: :ok | {:error, :realname_empty | :realname_too_long}
  defp validate_realname(realname) do
    max_realname_length = Application.get_env(:elixircd, :user)[:max_realname_length]

    cond do
      String.length(realname) == 0 -> {:error, :realname_empty}
      String.length(realname) > max_realname_length -> {:error, :realname_too_long}
      true -> :ok
    end
  end

  @spec change_realname(User.t(), String.t()) :: :ok
  defp change_realname(user, new_realname) do
    updated_user = Users.update(user, %{realname: new_realname})
    notify_setname(updated_user, new_realname)

    :ok
  end

  @spec notify_setname(User.t(), String.t()) :: :ok
  defp notify_setname(user, new_realname) do
    setname_supported = Application.get_env(:elixircd, :capabilities)[:setname] || false

    if setname_supported do
      watchers = Users.get_in_shared_channels_with_capability(user, "setname", true)

      # Include a capable sender even when they have no channels.
      watchers_with_self =
        [user | watchers]
        |> Enum.filter(&("setname" in &1.capabilities))
        |> Enum.uniq_by(& &1.pid)

      %Message{command: "SETNAME", params: [], trailing: new_realname}
      |> Dispatcher.broadcast(user, watchers_with_self)
    end

    :ok
  end
end
