defmodule ElixIRCd.Commands.Links do
  @moduledoc """
  Implements topology-redacted LINKS replies from the native manager.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [match_glob?: 2, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "LINKS"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "LINKS", params: params}) do
    mask = List.first(params) || "*"

    with {:ok, manager} <- manager() do
      Manager.topology_links(manager)
      |> Enum.filter(fn link -> match_glob?(link.name, mask) or match_glob?(link.sid, mask) end)
      |> Enum.each(&send_link(user, &1))
    end

    %Message{command: :rpl_endoflinks, params: [user_reply(user), mask], trailing: "End of /LINKS list"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_link(user, %{name: name, parent: parent, sid: sid}) do
    parent_name = if is_binary(parent), do: parent, else: "*"

    %Message{
      command: :rpl_links,
      params: [user_reply(user), name, parent_name, "0"],
      trailing: "ENP/1 #{sid}"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp manager do
    case Process.whereis(Manager) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :s2s_disabled}
    end
  end
end
