defmodule ElixIRCd.Commands.Connect do
  @moduledoc "Operator control for a configured native ENP/1 neighbor."

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "CONNECT"}),
    do: reply(user, :err_notregistered, ["*"], "You have not registered")

  def handle(user, %{command: "CONNECT", params: []}),
    do: reply(user, :err_needmoreparams, [user_reply(user), "CONNECT"], "Not enough parameters")

  def handle(user, %{command: "CONNECT", params: [target | _]}) do
    cond do
      not irc_operator?(user) ->
        reply(user, :err_noprivileges, [user_reply(user)], "Permission Denied- You're not an IRC operator")

      true ->
        case Process.whereis(Manager) do
          pid when is_pid(pid) ->
            case Manager.connect_neighbor(pid, target) do
              {:ok, :connecting} ->
                notice(user, "CONNECT accepted for #{target}; connecting to its configured parent")

              {:ok, :awaiting_child} ->
                notice(user, "CONNECT accepted for #{target}; awaiting the configured child")

              {:error, :unconfigured_neighbor} ->
                reply(user, :err_nosuchserver, [user_reply(user), target], "No such server")

              {:error, _reason} ->
                notice(user, "CONNECT rejected for #{target}")
            end

          _ ->
            notice(user, "CONNECT rejected for #{target}; native links are disabled")
        end
    end
  end

  defp notice(user, text), do: reply(user, "NOTICE", [user_reply(user)], text)

  defp reply(user, command, params, trailing) do
    %Message{command: command, params: params, trailing: trailing}
    |> Dispatcher.broadcast(:server, user)
  end
end
