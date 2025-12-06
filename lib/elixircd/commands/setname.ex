defmodule ElixIRCd.Commands.Setname do
  @moduledoc """
  This module defines the SETNAME command.

  SETNAME allows users to change their real name (GECOS) during an active session.
  This requires the SETNAME capability to be enabled.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "SETNAME"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "SETNAME", trailing: nil}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "SETNAME"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "SETNAME", trailing: new_realname}) do
    setname_supported = Application.get_env(:elixircd, :capabilities)[:setname] || false

    if setname_supported do
      max_realname_length = Application.get_env(:elixircd, :user)[:max_realname_length]

      cond do
        String.length(new_realname) == 0 ->
          %Message{command: "FAIL", params: ["SETNAME", "INVALID_REALNAME"], trailing: "Realname cannot be empty"}
          |> Dispatcher.broadcast(:server, user)

        String.length(new_realname) > max_realname_length ->
          %Message{
            command: "FAIL",
            params: ["SETNAME", "INVALID_REALNAME"],
            trailing: "Realname too long (maximum #{max_realname_length} characters)"
          }
          |> Dispatcher.broadcast(:server, user)

        new_realname == user.realname ->
          :ok

        true ->
          change_realname(user, new_realname)
      end
    else
      %Message{command: :err_unknowncommand, params: [user_reply(user), "SETNAME"], trailing: "Unknown command"}
      |> Dispatcher.broadcast(:server, user)
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
      watchers = Users.get_in_shared_channels_with_capability(user, "SETNAME", true)

      if watchers != [] do
        %Message{command: "SETNAME", params: [], trailing: new_realname}
        |> Dispatcher.broadcast(user, watchers)
      end
    end

    :ok
  end
end
