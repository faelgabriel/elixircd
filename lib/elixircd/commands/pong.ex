defmodule ElixIRCd.Commands.Pong do
  @moduledoc """
  Accepts client PONG replies without producing an IRC response.
  """
  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(_user, %{command: "PONG"}), do: :ok
end
