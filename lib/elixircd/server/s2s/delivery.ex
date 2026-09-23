defmodule ElixIRCd.Server.S2S.Delivery do
  @moduledoc """
  ENP/1 transient message routing and local C2S delivery.

  Messages carry their original UID/message ID through the tree. This module
  only computes destination homes and renders a trusted, already-admitted
  message for local sockets; it never persists or replays chat.
  """

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Schema
  alias ElixIRCd.Server.S2S.ServiceEndpoint
  alias ElixIRCd.Server.S2S.State
  alias ElixIRCd.Utils.MessageFilter

  @doc "Returns unique home SIDs that may receive one accepted message."
  @spec destination_sids(map(), map(), String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def destination_sids(runtime, frame, excluded_sid \\ nil) do
    with :ok <- Schema.validate_frame(frame),
         :ok <- valid_actor?(runtime, frame),
         :ok <- valid_audience_actor?(runtime, frame),
         {:ok, sids} <- target_sids(runtime, frame["target"]) do
      {:ok, sids |> Enum.reject(&(&1 == excluded_sid)) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc "Delivers a message to local C2S recipients selected by the target."
  @spec deliver_local(map(), map()) :: :ok | {:error, term()}
  def deliver_local(runtime, frame) do
    with :ok <- Schema.validate_frame(frame),
         :ok <- valid_actor?(runtime, frame),
         :ok <- valid_audience_actor?(runtime, frame),
         {:ok, message} <- render(frame, runtime),
         source_user <- source_user(runtime, frame["actor"]),
         recipients <- local_recipients(runtime, frame["target"], source_user, frame["command"]),
         :ok <- private_delivery_allowed(runtime, frame, source_user, recipients),
         :ok <- send_to_recipients(message, recipients) do
      :ok
    end
  rescue
    error -> {:error, {:delivery_failed, Exception.message(error)}}
  end

  @doc "Builds a C2S message without writing to a socket."
  @spec render(map(), map()) :: {:ok, Message.t()} | {:error, term()}
  def render(frame, runtime) do
    with {:ok, text} <- decode_nullable_bytes(frame["text"]),
         {:ok, tags} <- decode_tags(frame["tags"]),
         {:ok, target} <- target_text(frame["target"], runtime) do
      {:ok,
       %Message{
         prefix: source_prefix(frame["actor"], runtime),
         command: frame["command"],
         params: [target],
         trailing: text,
         tags: tags
       }}
    end
  end

  defp valid_actor?(runtime, %{"origin" => %{"sid" => origin_sid, "boot" => origin_boot}, "actor" => %{"user" => uid}}) do
    case runtime.users[uid] do
      %{"home" => %{"sid" => ^origin_sid, "boot" => ^origin_boot}} -> :ok
      nil -> {:error, :unknown_message_actor}
      _ -> {:error, :message_actor_home_mismatch}
    end
  end

  defp valid_actor?(_runtime, %{"origin" => %{"sid" => sid}, "actor" => %{"server" => sid}}), do: :ok

  defp valid_actor?(runtime, %{"origin" => %{"sid" => sid}, "actor" => %{"service" => service}}) do
    authority = Map.get(runtime, :services_authority)

    if service in ~w(NickServ ChanServ) and is_binary(authority) and authority == sid,
      do: :ok,
      else: {:error, :service_actor_not_authoritative}
  end

  defp valid_actor?(_runtime, _frame), do: {:error, :invalid_message_actor}

  defp valid_audience_actor?(_runtime, %{"target" => %{"audience" => _}, "actor" => %{"server" => _sid}}),
    do: :ok

  defp valid_audience_actor?(_runtime, %{"target" => %{"audience" => _}, "actor" => %{"service" => _service}}),
    do: :ok

  defp valid_audience_actor?(runtime, %{"target" => %{"audience" => _}, "actor" => %{"user" => uid}}) do
    case runtime.users[uid] do
      %{"oper_role" => role, "modes" => modes}
      when (is_binary(role) or is_nil(role)) and is_list(modes) ->
        if is_binary(role) or "o" in modes, do: :ok, else: {:error, :audience_actor_not_authorized}

      _ ->
        {:error, :audience_actor_not_authorized}
    end
  end

  defp valid_audience_actor?(_runtime, _frame), do: :ok

  defp private_delivery_allowed(
         runtime,
         %{"command" => "PRIVMSG", "target" => %{"user" => uid}},
         source_user,
         recipients
       ) do
    case local_target_user(runtime, uid) do
      {:ok, _target_user} when recipients != [] -> :ok
      {:ok, target_user} -> read_local_result(fn -> private_recipient_result(runtime, source_user, target_user) end)
      :missing -> {:error, {:message_rejected, [message_error_item(runtime, source_user, nil, "401", "No such nick")]}}
    end
  end

  defp private_delivery_allowed(_runtime, _frame, _source_user, _recipients), do: :ok

  defp local_target_user(runtime, uid) do
    case runtime.users[uid] do
      %{"home" => %{"sid" => sid, "boot" => boot}} when sid == runtime.sid ->
        case read_local_recipients(fn -> Users.get_by_uid(uid) end) do
          {:ok, user} when is_pid(user.pid) ->
            if local_user_current?(runtime, user, sid, boot), do: {:ok, user}, else: :missing

          _ ->
            :missing
        end

      _ ->
        :missing
    end
  end

  defp private_recipient_result(runtime, source_user, target_user) do
    cond do
      is_nil(source_user) ->
        :ok

      MessageFilter.should_silence_message?(target_user, source_user) ->
        :ok

      :R in target_user.modes and :r not in source_user.modes ->
        {:error,
         {:message_rejected,
          [
            message_error_item(
              runtime,
              source_user,
              target_user,
              "477",
              "You must be identified to message this user"
            )
          ]}}

      :g in target_user.modes and
          is_nil(UserAccepts.get_by_user_pid_and_accepted_uid(target_user.pid, source_user.uid)) ->
        {:error,
         {:message_rejected,
          [
            message_error_item(
              runtime,
              source_user,
              target_user,
              "716",
              "Your message has been blocked. #{target_user.nick} is only accepting messages from authorized users."
            )
          ]}}

      true ->
        {:error, {:message_rejected, [message_error_item(runtime, source_user, target_user, "401", "No such nick")]}}
    end
  end

  defp message_error_item(runtime, source_user, target_user, command, trailing) do
    sender_nick = if source_user && is_binary(source_user.nick), do: source_user.nick, else: "*"
    target_nick = if target_user && is_binary(target_user.nick), do: target_user.nick, else: "*"

    %{
      "command" => command,
      "params" => [sender_nick, target_nick],
      "trailing" => trailing,
      "source" => %{"server" => runtime.sid},
      "tags" => %{}
    }
  end

  defp target_sids(runtime, %{"user" => uid}) do
    case runtime.users[uid] do
      %{"home" => %{"sid" => sid}} -> {:ok, [sid]}
      nil -> {:error, :message_target_unavailable}
    end
  end

  defp target_sids(runtime, %{"channel" => ref, "minimum_status" => minimum}) do
    with {:ok, channel} <- fetch_channel(runtime, ref) do
      sids =
        runtime.memberships
        |> Enum.flat_map(fn {uid, membership} ->
          case runtime.users[uid] do
            %{"home" => %{"sid" => sid}} ->
              if current_membership?(runtime, membership, ref["name"]) and
                   status_allowed?(channel, uid, membership, ref["name"], minimum, runtime.case_mapping),
                 do: [sid],
                 else: []

            _ ->
              []
          end
        end)

      {:ok, sids}
    end
  end

  defp target_sids(runtime, %{"audience" => audience, "mask" => mask})
       when audience in ~w(wallops operators snomask) do
    sids =
      runtime.users
      |> Map.values()
      |> Enum.filter(&audience_projection_allowed?(&1, audience, mask))
      |> Enum.map(&get_in(&1, ["home", "sid"]))
      |> Enum.reject(&is_nil/1)

    {:ok, sids}
  end

  defp target_sids(_runtime, _target), do: {:error, :invalid_message_target}

  defp fetch_channel(runtime, ref) do
    case runtime.channels[normalize(ref["name"], runtime.case_mapping)] do
      nil ->
        {:error, :message_channel_unavailable}

      channel ->
        case State.incarnation(%{born_ms: channel.ref["born_ms"], cid: channel.ref["cid"]}, %{
               born_ms: ref["born_ms"],
               cid: ref["cid"]
             }) do
          :same -> {:ok, channel}
          _ -> {:error, :stale_message_channel}
        end
    end
  end

  defp current_membership?(runtime, membership, name) do
    Enum.any?(
      membership.entries,
      &(normalize(&1["channel"], runtime.case_mapping) == normalize(name, runtime.case_mapping))
    )
  end

  defp status_allowed?(_channel, _uid, _membership, _name, nil, _case_mapping), do: true

  defp status_allowed?(channel, uid, membership, name, minimum, case_mapping) do
    entry = Enum.find(membership.entries, &(normalize(&1["channel"], case_mapping) == normalize(name, case_mapping)))

    if entry do
      operator? = enabled_status?(channel, {uid, entry["join_id"], "o"})
      voice? = enabled_status?(channel, {uid, entry["join_id"], "v"})
      (minimum == "o" and operator?) or (minimum == "v" and (operator? or voice?))
    else
      false
    end
  end

  defp enabled_status?(channel, key) do
    case channel.statuses[key] do
      %{value: %{enabled: true}} -> true
      _ -> false
    end
  end

  defp local_recipients(runtime, %{"user" => uid}, source_user, command) do
    read_local_recipients(fn -> do_local_recipients(runtime, %{"user" => uid}, source_user, command) end)
  end

  defp local_recipients(runtime, %{"channel" => _ref} = target, source_user, command) do
    read_local_recipients(fn -> do_local_recipients(runtime, target, source_user, command) end)
  end

  defp local_recipients(runtime, %{"audience" => _audience} = target, source_user, command) do
    read_local_recipients(fn -> do_local_recipients(runtime, target, source_user, command) end)
  end

  defp local_recipients(_runtime, _target, _source_user, _command), do: []

  defp do_local_recipients(runtime, %{"user" => uid}, source_user, command) do
    case runtime.users[uid] do
      %{"home" => %{"sid" => sid}} when sid == runtime.sid ->
        case Users.get_by_uid(uid) do
          {:ok, user} when is_pid(user.pid) ->
            if local_user_current?(runtime, user) and private_recipient_allowed?(user, source_user) and
                 message_allowed?(user, command),
               do: [user],
               else: []

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp do_local_recipients(runtime, %{"channel" => ref, "minimum_status" => minimum}, _source_user, command) do
    if current_local_channel?(runtime, ref) do
      UserChannels.get_by_channel_name(ref["name"])
      |> Enum.flat_map(fn record ->
        with {:ok, user} <- Users.get_by_pid(record.user_pid),
             true <- local_user_current?(runtime, user),
             true <- is_nil(minimum) or status_record_allowed?(record, minimum),
             true <- message_allowed?(user, command) do
          [user]
        else
          _ -> []
        end
      end)
      |> Enum.uniq_by(& &1.pid)
    else
      []
    end
  end

  defp do_local_recipients(runtime, %{"audience" => audience, "mask" => mask}, _source_user, command)
       when audience in ~w(wallops operators snomask) do
    Users.get_all()
    |> Enum.filter(fn user ->
      local_user_current?(runtime, user) and
        audience_user_allowed?(user, audience, mask) and
        message_allowed?(user, command)
    end)
  end

  defp do_local_recipients(_runtime, _target, _source_user, _command), do: []

  defp current_local_channel?(_runtime, %{"name" => name, "born_ms" => born_ms, "cid" => cid})
       when is_binary(name) and is_integer(born_ms) and is_binary(cid) do
    with {:ok, channel} <- Channels.get_by_name(name),
         :same <- State.incarnation(%{born_ms: channel.born_ms || 1, cid: channel.cid}, %{born_ms: born_ms, cid: cid}) do
      true
    else
      _ -> false
    end
  end

  defp current_local_channel?(_runtime, _ref), do: false

  defp local_user_current?(runtime, user), do: local_user_current?(runtime, user, runtime.sid, nil)

  defp local_user_current?(runtime, user, expected_sid, expected_boot) do
    case runtime.users[user.uid] do
      %{"home" => %{"sid" => ^expected_sid, "boot" => boot}} ->
        (is_nil(expected_boot) or boot == expected_boot) and
          user.home_sid in [nil, expected_sid] and
          (is_nil(user.home_boot) or user.home_boot == boot)

      _ ->
        false
    end
  end

  defp audience_projection_allowed?(%{"modes" => modes} = user, audience, mask) when is_list(modes) do
    case audience do
      "wallops" -> "w" in modes
      "operators" -> user["oper_role"] != nil or "o" in modes
      "snomask" -> "s" in modes and snomask_mask_allowed?(mask)
      _ -> false
    end
  end

  defp audience_projection_allowed?(_user, _audience, _mask), do: false

  defp audience_user_allowed?(%{modes: modes}, audience, mask) when is_list(modes) do
    case audience do
      "wallops" -> :w in modes
      "operators" -> :o in modes
      "snomask" -> :s in modes and snomask_mask_allowed?(mask)
      _ -> false
    end
  end

  defp audience_user_allowed?(_user, _audience, _mask), do: false

  defp snomask_mask_allowed?(mask), do: is_nil(mask) or is_binary(mask)

  defp read_local_recipients(fun) when is_function(fun, 0) do
    if Memento.Transaction.inside?(), do: fun.(), else: Memento.transaction!(fun)
  catch
    :exit, _reason -> []
  end

  defp read_local_result(fun) when is_function(fun, 0) do
    if Memento.Transaction.inside?(), do: fun.(), else: Memento.transaction!(fun)
  catch
    :exit, _reason -> {:error, :local_state_unavailable}
  end

  defp source_user(runtime, %{"user" => uid}) do
    case ServiceEndpoint.caller_user(runtime, uid) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp source_user(_runtime, _actor), do: nil

  defp private_recipient_allowed?(_recipient, nil), do: true

  defp private_recipient_allowed?(recipient, source) do
    not MessageFilter.should_silence_message?(recipient, source) and
      not (:R in recipient.modes and :r not in source.modes) and
      not (:g in recipient.modes and
             is_nil(UserAccepts.get_by_user_pid_and_accepted_uid(recipient.pid, source.uid)))
  end

  defp message_allowed?(%{capabilities: capabilities}, "TAGMSG"), do: "message-tags" in capabilities
  defp message_allowed?(_user, _command), do: true

  defp status_record_allowed?(record, "o"), do: :o in record.modes
  defp status_record_allowed?(record, "v"), do: :o in record.modes or :v in record.modes
  defp status_record_allowed?(_record, _minimum), do: false

  defp send_to_recipients(message, recipients) do
    Enum.each(recipients, &Dispatcher.send_prepared_message(message, &1))
    :ok
  end

  defp target_text(%{"user" => uid}, runtime) do
    case runtime.users[uid] do
      %{"effective_nick" => nick} when is_binary(nick) -> {:ok, nick}
      %{"requested_nick" => nick} when is_binary(nick) -> {:ok, nick}
      _ -> {:error, :message_target_unavailable}
    end
  end

  defp target_text(%{"channel" => %{"name" => name}, "minimum_status" => minimum}, _runtime)
       when is_binary(name) and minimum in [nil, "o", "v"] do
    prefix = %{"o" => "@", "v" => "+", nil => ""}[minimum]
    {:ok, prefix <> name}
  end

  defp target_text(%{"audience" => audience}, _runtime), do: {:ok, "@" <> audience}
  defp target_text(_target, _runtime), do: {:error, :invalid_message_target}

  defp source_prefix(%{"server" => sid}, _runtime), do: sid
  defp source_prefix(%{"service" => "NickServ"}, _runtime), do: service_mask(:nickserv)
  defp source_prefix(%{"service" => "ChanServ"}, _runtime), do: service_mask(:chanserv)

  defp source_prefix(%{"user" => uid}, runtime) do
    user = runtime.users[uid] || %{}
    ident = Map.get(user, "ident", "unknown")
    host = Map.get(user, "displayhost", Map.get(user, "realhost", "unknown"))
    nick = Map.get(user, "effective_nick", Map.get(user, "requested_nick", uid))
    "#{nick}!#{ident}@#{host}"
  end

  defp service_mask(service) do
    ElixIRCd.Service.mask(service)
  rescue
    _ -> Atom.to_string(service)
  end

  defp decode_nullable_bytes(nil), do: {:ok, nil}
  defp decode_nullable_bytes(value) when is_binary(value), do: {:ok, value}

  defp decode_nullable_bytes(%{"b64" => encoded} = value) when map_size(value) == 1 do
    case Base.decode64(encoded) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_message_bytes}
    end
  end

  defp decode_nullable_bytes(_value), do: {:error, :invalid_message_bytes}

  defp decode_tags(tags) when is_map(tags) do
    Enum.reduce_while(tags, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case decode_nullable_bytes(value) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp decode_tags(_tags), do: {:error, :invalid_message_tags}

  defp normalize(value, :ascii), do: ascii_lower(value)

  defp normalize(value, :strict_rfc1459),
    do:
      value
      |> ascii_lower()
      |> String.replace(["{", "}", "|"], fn
        "{" -> "["
        "}" -> "]"
        "|" -> "\\"
      end)

  defp normalize(value, _mapping),
    do:
      value
      |> ascii_lower()
      |> String.replace(["{", "}", "|", "~"], fn
        "{" -> "["
        "}" -> "]"
        "|" -> "\\"
        "~" -> "^"
      end)

  defp ascii_lower(value) when is_binary(value),
    do: for(<<byte <- value>>, into: <<>>, do: <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>)
end
