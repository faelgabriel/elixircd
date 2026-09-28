defmodule ElixIRCd.Commands.Metadata do
  @moduledoc "IRCv3 metadata-2 implementation with metadata-3 draft compatibility."

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Metadata
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.WireChunks

  @impl true
  def handle(user, message) do
    cond do
      current_available?(user) -> dispatch(user, message)
      legacy_available?(user) -> dispatch_legacy(user, message)
      true -> fail(user, "NEED_CAP", "*", "The metadata capability and batch are required")
    end
  end

  defp dispatch_legacy(user, %{params: [target, "GET" | keys]}) when keys != [] do
    case Metadata.resolve_target(user, target) do
      {:ok, resolved} ->
        Enum.each(keys, &send_legacy_key(user, resolved, &1))

      {:error, _reason} ->
        legacy_target_error(user, target)
    end
  end

  defp dispatch_legacy(user, %{params: [target, "LIST"]}) do
    case Metadata.resolve_target(user, target) do
      {:ok, resolved} ->
        Enum.each(Metadata.list(resolved), &legacy_value(user, &1))
        legacy_end(user, target)

      {:error, _reason} ->
        legacy_target_error(user, target)
    end
  end

  defp dispatch_legacy(user, %{params: [target, "SET", key], trailing: value}) do
    with {:ok, resolved} <- Metadata.resolve_target(user, target),
         true <- Metadata.writable?(user, resolved),
         true <- Metadata.valid_key?(key),
         true <- Metadata.valid_value?(value),
         true <- Metadata.get(resolved, key) != nil or Metadata.target_key_count(resolved) < Metadata.max_keys() do
      resolved |> Metadata.put(key, value) |> then(&legacy_value(user, &1))
      legacy_end(user, target)
    else
      {:error, _reason} -> legacy_target_error(user, target)
      false -> legacy_error(user, "769", key, "Permission denied or invalid metadata value")
    end
  end

  defp dispatch_legacy(user, %{params: [target | _]}), do: legacy_target_error(user, target)
  defp dispatch_legacy(user, _message), do: legacy_target_error(user, "*")

  defp dispatch(user, %{params: [target, "GET" | keys]}) when keys != [] do
    case Metadata.resolve_target(user, target) do
      {:ok, resolved} -> send_keys(user, resolved, keys)
      {:error, reason} -> target_error(user, target, reason)
    end
  end

  defp dispatch(user, %{params: [target, "LIST"]}) do
    case Metadata.resolve_target(user, target) do
      {:ok, resolved} -> send_entries(user, resolved)
      {:error, reason} -> target_error(user, target, reason)
    end
  end

  defp dispatch(user, %{params: [target, "SET", key], trailing: value}) do
    with {:ok, resolved} <- Metadata.resolve_target(user, target),
         :ok <- writable(user, resolved, key),
         :ok <- valid_key(key),
         :ok <- set_value(user, resolved, key, value) do
      :ok
    else
      {:error, :invalid_target} -> target_error(user, target, :invalid_target)
      {:error, :no_permission} -> fail(user, "KEY_NO_PERMISSION", [target, key], "Permission denied")
      {:error, :invalid_key} -> fail(user, "KEY_INVALID", key, "Invalid metadata key")
      {:error, :invalid_value} -> invalid_value_error(user, key)
      {:error, :limit_reached} -> fail(user, "LIMIT_REACHED", target, "Metadata limit reached")
      {:error, :not_set} -> fail(user, "KEY_NOT_SET", [target, key], "Metadata key is not set")
    end
  end

  defp dispatch(user, %{params: [target, "CLEAR"]}) do
    with {:ok, resolved} <- Metadata.resolve_target(user, target),
         true <- Metadata.writable?(user, resolved) do
      entries = Metadata.clear(resolved)

      ResponseContext.with_batch("metadata", [resolved.name], fn ->
        Enum.each(entries, &Metadata.send_not_set(user, resolved.name, &1.key))
      end)
    else
      {:error, reason} -> target_error(user, target, reason)
      false -> fail(user, "KEY_NO_PERMISSION", [target, "*"], "Permission denied")
    end
  end

  defp dispatch(user, %{params: ["*", "SUB" | keys]}) when keys != [] do
    subscribe(user, keys)
  end

  defp dispatch(user, %{params: ["*", "UNSUB" | keys]}) when keys != [] do
    valid =
      Enum.filter(keys, fn key ->
        if Metadata.valid_key?(key),
          do:
            (
              Metadata.unsubscribe(user, key)
              true
            ),
          else:
            (
              fail(user, "KEY_INVALID", key, "Invalid metadata key")
              false
            )
      end)

    if valid != [] do
      send_key_list(user, "771", valid)
    end
  end

  defp dispatch(user, %{params: ["*", "SUBS"]}) do
    ResponseContext.with_batch("metadata-subs", [], fn ->
      case Metadata.subscriptions(user) do
        [] ->
          :ok

        subscriptions ->
          send_key_list(user, "772", subscriptions)
      end
    end)
  end

  defp dispatch(user, %{params: [target, "SYNC"]}) do
    case Metadata.resolve_target(user, target) do
      {:ok, resolved} -> Metadata.sync_target(user, resolved)
      {:error, reason} -> target_error(user, target, reason)
    end
  end

  defp dispatch(user, %{params: [_target, subcommand | _]}) do
    fail(user, "SUBCOMMAND_INVALID", subcommand, "Invalid METADATA subcommand")
  end

  defp dispatch(user, _message), do: fail(user, "INVALID_PARAMS", "*", "Invalid METADATA parameters")

  defp send_legacy_key(user, resolved, key) do
    cond do
      not Metadata.valid_key?(key) -> legacy_error(user, "767", key, "Invalid metadata key")
      entry = Metadata.get(resolved, key) -> legacy_value(user, entry)
      true -> legacy_not_set(user, key)
    end
  end

  defp send_keys(user, resolved, keys) do
    ResponseContext.with_batch("metadata", [resolved.name], fn ->
      Enum.each(keys, &send_key(user, resolved, &1))
    end)
  end

  defp send_key(user, resolved, key) do
    cond do
      not Metadata.valid_key?(key) -> fail(user, "KEY_INVALID", key, "Invalid metadata key")
      entry = Metadata.get(resolved, key) -> Metadata.send_value(user, resolved.name, entry)
      true -> Metadata.send_not_set(user, resolved.name, key)
    end
  end

  defp send_entries(user, resolved) do
    ResponseContext.with_batch("metadata", [resolved.name], fn ->
      Enum.each(Metadata.list(resolved), &Metadata.send_value(user, resolved.name, &1))
    end)
  end

  defp subscribe(user, keys) do
    {accepted, _count} =
      Enum.reduce_while(keys, {[], length(Metadata.subscriptions(user))}, fn key, {accepted, count} ->
        cond do
          not Metadata.valid_key?(key) ->
            fail(user, "KEY_INVALID", key, "Invalid metadata key")
            {:cont, {accepted, count}}

          key in accepted or key in Metadata.subscriptions(user) ->
            {:cont, {accepted ++ [key], count}}

          count >= Metadata.max_subscriptions() ->
            fail(user, "TOO_MANY_SUBS", key, "Too many metadata subscriptions")
            {:halt, {accepted, count}}

          true ->
            Metadata.subscribe(user, key)
            {:cont, {accepted ++ [key], count + 1}}
        end
      end)

    if accepted != [] do
      send_key_list(user, "770", accepted)
    end
  end

  defp send_key_list(user, command, keys) do
    WireChunks.split(keys, fn chunk, _continuation? ->
      %Message{prefix: Dispatcher.server_prefix(), command: command, params: [reply_target(user) | chunk]}
    end)
    |> Dispatcher.broadcast(:server, user)
  end

  defp set_value(user, target, key, nil) do
    case Metadata.delete(target, key) do
      :not_found -> {:error, :not_set}
      _entry -> Metadata.send_not_set(user, target.name, key)
    end
  end

  defp set_value(user, target, key, value) do
    cond do
      not Metadata.valid_value?(value) ->
        {:error, :invalid_value}

      Metadata.get(target, key) == nil and Metadata.target_key_count(target) >= Metadata.max_keys() ->
        {:error, :limit_reached}

      true ->
        entry = Metadata.put(target, key, value)
        Metadata.send_value(user, target.name, entry)
    end
  end

  defp writable(user, target, _key), do: if(Metadata.writable?(user, target), do: :ok, else: {:error, :no_permission})
  defp valid_key(key), do: if(Metadata.valid_key?(key), do: :ok, else: {:error, :invalid_key})

  defp current_available?(user) do
    Metadata.enabled?() and Metadata.capable?(user) and "batch" in user.capabilities and
      (user.registered or Application.fetch_env!(:elixircd, :metadata)[:before_connect])
  end

  defp legacy_available?(user) do
    config = Application.fetch_env!(:elixircd, :compatibility)
    Metadata.enabled?() and config[:deprecated_metadata] and user.registered and not Metadata.capable?(user)
  end

  defp legacy_value(user, entry) do
    %Message{command: "761", params: [reply_target(user), entry.key, entry.visibility], trailing: entry.value}
    |> Dispatcher.broadcast(:server, user)
  end

  defp legacy_not_set(user, key),
    do: legacy_error(user, "766", key, "No matching metadata key")

  defp legacy_end(user, target) do
    %Message{command: "762", params: [reply_target(user), target], trailing: "End of metadata"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp legacy_target_error(user, target),
    do: legacy_error(user, "765", target, "Invalid metadata target")

  defp legacy_error(user, numeric, context, description) do
    %Message{command: numeric, params: [reply_target(user), context], trailing: description}
    |> Dispatcher.broadcast(:server, user)
  end

  defp target_error(user, target, :no_permission),
    do: fail(user, "KEY_NO_PERMISSION", [target, "*"], "Permission denied")

  defp target_error(user, target, _reason), do: fail(user, "INVALID_TARGET", target, "Invalid metadata target")

  defp invalid_value_error(user, key) do
    if "draft/metadata-2" in user.capabilities do
      fail(user, "VALUE_INVALID", [], "Invalid metadata value")
    else
      fail(user, "INVALID_VALUE", key, "Invalid metadata value")
    end
  end

  defp fail(user, code, context, description) do
    %StandardReply{
      type: :fail,
      command: "METADATA",
      code: code,
      context: List.wrap(context),
      description: description
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp reply_target(%User{nick: nil}), do: "*"
  defp reply_target(%User{nick: nick}), do: nick
end
