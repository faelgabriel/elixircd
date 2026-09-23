defmodule ElixIRCd.Commands.Chathistory do
  @moduledoc "IRCv3 CHATHISTORY retrieval with persistent, privacy-scoped storage."

  @behaviour ElixIRCd.Command

  alias ElixIRCd.History
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User

  @subcommands ["LATEST", "BEFORE", "AFTER", "BETWEEN", "AROUND"]

  @impl true
  def handle(%User{registered: false} = user, _message), do: fail(user, "INVALID_PARAMS", "*", "Registration required")

  def handle(user, %{params: ["TARGETS", lower, upper, limit]}) do
    with :ok <- available(user),
         {:ok, lower_reference} <- parse_target_timestamp(lower),
         {:ok, upper_reference} <- parse_target_timestamp(upper),
         {:ok, parsed_limit} <- parse_limit(limit) do
      send_targets(user, lower_reference, upper_reference, parsed_limit)
    else
      {:error, reason} -> handle_error(user, "TARGETS", "*", reason)
    end
  end

  def handle(user, %{params: [subcommand, target, first, second, limit]}) when subcommand == "BETWEEN" do
    with :ok <- available(user),
         {:ok, target_info} <- History.target_for_request(user, target),
         {:ok, first_reference} <- History.parse_reference(first),
         {:ok, second_reference} <- History.parse_reference(second),
         {:ok, parsed_limit} <- parse_limit(limit) do
      send_history(user, target_info, subcommand, first_reference, second_reference, parsed_limit)
    else
      {:error, reason} -> handle_error(user, subcommand, target, reason)
    end
  end

  def handle(user, %{params: [subcommand, target, reference, limit]}) when subcommand in @subcommands do
    with :ok <- available(user),
         {:ok, target_info} <- History.target_for_request(user, target),
         {:ok, parsed_reference} <- History.parse_reference(reference),
         {:ok, parsed_limit} <- parse_limit(limit) do
      send_history(user, target_info, subcommand, parsed_reference, nil, parsed_limit)
    else
      {:error, reason} -> handle_error(user, subcommand, target, reason)
    end
  end

  def handle(user, %{params: [subcommand | _]}) do
    fail(user, "INVALID_PARAMS", subcommand, "Invalid CHATHISTORY parameters")
  end

  def handle(user, _message), do: fail(user, "INVALID_PARAMS", "*", "Invalid CHATHISTORY parameters")

  defp available(user) do
    if History.enabled?() and "draft/chathistory" in user.capabilities do
      :ok
    else
      {:error, :unavailable}
    end
  end

  defp parse_target_timestamp("timestamp=" <> _ = value) do
    History.parse_reference(value)
  end

  defp parse_target_timestamp(_value), do: {:error, :invalid_reference}

  defp parse_limit(value) do
    max_limit = Application.fetch_env!(:elixircd, :history)[:max_request_limit]

    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> {:ok, min(limit, max_limit)}
      _ -> {:error, :invalid_params}
    end
  end

  defp send_history(user, target, subcommand, first, second, limit) do
    entries = History.query(target.key, subcommand, first, second, limit, "draft/event-playback" in user.capabilities)

    send_reply(user, "chathistory", [target.name], fn -> Enum.each(entries, &History.replay(&1, user)) end)

    :ok
  end

  defp send_targets(user, lower, upper, limit) do
    targets = History.targets_for_request(user, lower, upper, limit)

    send_reply(user, "draft/chathistory-targets", [], fn ->
      Enum.each(targets, fn {target, timestamp} ->
        %ElixIRCd.Message{
          command: "CHATHISTORY",
          params: ["TARGETS", target, timestamp |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()]
        }
        |> Dispatcher.broadcast(:server, user)
      end)
    end)

    :ok
  end

  defp send_reply(user, type, params, callback) do
    if "batch" in user.capabilities,
      do: ResponseContext.with_batch(type, params, callback),
      else: callback.()
  end

  defp handle_error(user, subcommand, target, :invalid_target),
    do: fail(user, "INVALID_TARGET", [subcommand, target], "Invalid history target")

  defp handle_error(user, subcommand, _target, :unavailable),
    do: fail(user, "NEED_CAP", subcommand, "CHATHISTORY capability is required")

  defp handle_error(user, subcommand, _target, _reason),
    do: fail(user, "INVALID_PARAMS", subcommand, "Invalid CHATHISTORY parameters")

  defp fail(user, code, context, description) do
    %StandardReply{
      type: :fail,
      command: "CHATHISTORY",
      code: code,
      context: List.wrap(context),
      description: description
    }
    |> Dispatcher.broadcast(:server, user)
  end
end
