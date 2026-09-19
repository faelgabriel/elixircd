defmodule ElixIRCd.Commands.Links do
  @moduledoc """
  Implements topology-redacted LINKS replies.

  ElixIRCd currently operates as a single server with integrated services, so
  it deliberately exposes no link topology and only sends RPL_ENDOFLINKS.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "LINKS"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "LINKS"}) do
    %Message{command: :rpl_endoflinks, params: [user.nick, "*"], trailing: "End of /LINKS list"}
    |> Dispatcher.broadcast(:server, user)
  end
end
