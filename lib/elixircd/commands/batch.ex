defmodule ElixIRCd.Commands.Batch do
  @moduledoc "Handles client-originated IRCv3 BATCH messages."

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Multiline

  @impl true
  def handle(user, %Message{params: ["+" <> reference, "draft/multiline", target | _], tags: tags}) do
    Multiline.start(user, reference, target, tags)
  end

  def handle(user, %Message{params: ["-" <> reference | _]}), do: Multiline.finish(user, reference)
  def handle(user, _message), do: Multiline.start(user, "", "", %{})
end
