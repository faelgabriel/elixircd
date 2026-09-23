defmodule ElixIRCd.Commands.Squit do
  @moduledoc "Operator control for a configured direct native ENP/1 edge."

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "SQUIT"}),
    do: reply(user, :err_notregistered, ["*"], "You have not registered")

  def handle(user, %{command: "SQUIT", params: []}),
    do: reply(user, :err_needmoreparams, [user_reply(user), "SQUIT"], "Not enough parameters")

  def handle(user, %{command: "SQUIT", params: [target | _], trailing: reason}) do
    cond do
      not irc_operator?(user) ->
        reply(user, :err_noprivileges, [user_reply(user)], "Permission Denied- You're not an IRC operator")

      true ->
        case Process.whereis(Manager) do
          pid when is_pid(pid) ->
            case Manager.disable_neighbor(pid, target, reason || "operator SQUIT") do
              :ok ->
                reply(user, "NOTICE", [user_reply(user)], "SQUIT closed and disabled #{target}")

              {:error, :unconfigured_neighbor} ->
                reply(user, :err_nosuchserver, [user_reply(user), target], "No such server")

              {:error, _} ->
                reply(user, "NOTICE", [user_reply(user)], "SQUIT rejected for #{target}")
            end

          _ ->
            reply(user, :err_nosuchserver, [user_reply(user), target], "No such server")
        end
    end
  end

  defp reply(user, command, params, trailing) do
    %Message{command: command, params: params, trailing: trailing}
    |> Dispatcher.broadcast(:server, user)
  end
end
