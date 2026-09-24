defmodule ElixIRCd.Commands.Markread do
  @moduledoc "Implements monotonic IRCv3 MARKREAD storage and session propagation."

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.ReadMarkers
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.StandardReply

  @impl true
  def handle(user, %{params: [target]}) do
    case available(user) do
      :ok -> ReadMarkers.message(user, target) |> Dispatcher.broadcast(:server, user)
      {:error, reason} -> fail(user, reason)
    end
  end

  def handle(user, %{params: [target, "timestamp=" <> timestamp | _]}) do
    with :ok <- available(user),
         {:ok, parsed, _offset} <- DateTime.from_iso8601(timestamp),
         {:ok, stored} <- ReadMarkers.set(user, target, parsed) do
      message = %Message{command: "MARKREAD", params: [target, "timestamp=" <> DateTime.to_iso8601(stored)]}
      propagate(user, message)
    else
      {:error, :unavailable} -> fail(user, :unavailable)
      _ -> fail(user, :invalid_params)
    end
  end

  def handle(user, %{params: []}), do: fail(user, :need_more_params)
  def handle(user, _message), do: fail(user, :invalid_params)

  defp available(user) do
    if ReadMarkers.enabled?() and "draft/read-marker" in user.capabilities, do: :ok, else: {:error, :unavailable}
  end

  defp propagate(user, message) do
    owner = ReadMarkers.owner_key(user)

    sessions =
      if user.identified_as_key do
        Users.get_by_identified_as(user.identified_as)
      else
        [user]
      end

    sessions
    |> Enum.filter(fn candidate ->
      ReadMarkers.owner_key(candidate) == owner and "draft/read-marker" in candidate.capabilities
    end)
    |> then(&Dispatcher.broadcast(message, :server, &1))
  end

  defp fail(user, reason) do
    {code, description} =
      case reason do
        :need_more_params -> {"NEED_MORE_PARAMS", "MARKREAD requires a target"}
        :invalid_params -> {"INVALID_PARAMS", "Invalid MARKREAD timestamp"}
        :unavailable -> {"NEED_CAP", "Read-marker capability is required"}
      end

    %StandardReply{type: :fail, command: "MARKREAD", code: code, description: description}
    |> Dispatcher.broadcast(:server, user)
  end
end
