defmodule ElixIRCd.History do
  @moduledoc "Records and retrieves privacy-scoped IRCv3 chat history."

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.ChatHistory, as: HistoryRepository
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.Tables.ChatHistory
  alias ElixIRCd.Tables.ClientBatch
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @message_commands ["PRIVMSG", "NOTICE", "TAGMSG"]
  @automatically_recorded_event_commands ["PART", "KICK", "MODE", "TOPIC"]
  @playback_event_commands ["JOIN", "PART", "KICK", "MODE", "NICK", "QUIT", "RENAME", "TOPIC", "TAGMSG"]

  @type history_reference :: :all | {:msgid, String.t()} | {:timestamp, DateTime.t()}

  defmodule RemoteIdentity do
    @moduledoc "A remote user's home and UID, kept separate from local account and nickname identities."

    @enforce_keys [:origin, :uid, :nick]
    defstruct [:origin, :uid, :nick]

    @type t :: %__MODULE__{origin: String.t(), uid: String.t(), nick: String.t()}
  end

  @doc "Whether persistent history is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.fetch_env!(:elixircd, :history)[:enabled]

  @doc "Whether a prepared user message belongs in persistent history."
  @spec recordable?(Message.t()) :: boolean()
  def recordable?(%Message{command: command}),
    do: command in @message_commands or command in @automatically_recorded_event_commands

  @doc "Records one accepted, fully prepared user message."
  @spec record(Message.t(), User.t()) :: :ok
  def record(%Message{command: command} = message, %User{} = sender) when command in @message_commands do
    transactional(fn -> do_record(message, sender) end)
  end

  def record(%Message{command: command} = message, %User{} = sender)
      when command in @automatically_recorded_event_commands do
    if message.params |> List.first() |> channel_name?(),
      do: transactional(fn -> do_record(message, sender) end),
      else: :ok
  end

  def record(_message, _sender), do: :ok

  @doc "Records an accepted message from a local sender to one authenticated remote UID."
  @spec record_remote_outgoing(Message.t(), User.t(), RemoteIdentity.t()) :: :ok
  def record_remote_outgoing(%Message{} = message, %User{} = sender, %RemoteIdentity{} = remote) do
    transactional(fn ->
      do_record_remote(message, identity_key(sender), remote_identity_key(remote), remote.nick, :outgoing)
    end)
  end

  @doc "Records an accepted message from one authenticated remote UID to a local recipient."
  @spec record_remote_incoming(Message.t(), RemoteIdentity.t(), User.t()) :: :ok
  def record_remote_incoming(%Message{} = message, %RemoteIdentity{} = remote, %User{} = recipient) do
    transactional(fn ->
      do_record_remote(message, remote_identity_key(remote), identity_key(recipient), remote.nick, :incoming)
    end)
  end

  @doc "Records a channel-scoped event whose wire form does not identify its channel."
  @spec record_channel_event(Message.t(), User.t(), String.t()) :: :ok
  def record_channel_event(%Message{} = message, %User{} = sender, channel_name) do
    transactional(fn ->
      if enabled?() do
        timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond)
        msgid = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

        prepared = %{
          message
          | prefix: message.prefix || user_mask(sender),
            tags:
              message.tags
              |> Map.put_new("msgid", msgid)
              |> Map.put_new("time", DateTime.to_iso8601(timestamp))
        }

        target_key = "channel:" <> CaseMapping.normalize(channel_name)

        HistoryRepository.create(%{
          id: {target_key, DateTime.to_unix(timestamp, :microsecond), prepared.tags["msgid"]},
          target_type: :channel,
          target_key: target_key,
          target_name: channel_name,
          msgid: prepared.tags["msgid"],
          sender_account_key: identity_key(sender),
          recipient_account_key: nil,
          message: prepared,
          occurred_at: timestamp
        })

        prune_target(target_key, timestamp)
        Observability.defer([:history], %{count: 1}, %{operation: :write_event})
      end
    end)

    :ok
  end

  @doc "Records one accepted multiline message as a replayable nested batch."
  @spec record_multiline(User.t(), ClientBatch.t(), [{Message.t(), [User.t()]}], String.t(), String.t()) :: :ok
  def record_multiline(sender, batch, records, msgid, timestamp) do
    transactional(fn ->
      with true <- enabled?(),
           {:ok, occurred_at, _offset} <- DateTime.from_iso8601(timestamp),
           {:ok, target} <- storage_target(sender, batch.target) do
        id = {target.key, DateTime.to_unix(occurred_at, :microsecond), msgid}

        HistoryRepository.create(%{
          id: id,
          target_type: target.type,
          target_key: target.key,
          target_name: target.name,
          msgid: msgid,
          sender_account_key: identity_key(sender),
          recipient_account_key: target[:recipient_account_key],
          message: %{
            kind: :multiline,
            target: batch.target,
            tags: Map.drop(batch.tags, ["batch", "label", "msgid", "time"]),
            lines: Enum.map(records, fn {message, _recipients} -> message end)
          },
          occurred_at: occurred_at
        })

        prune_target(target.key, occurred_at)
        Observability.defer([:history], %{count: 1}, %{operation: :write_multiline})
      else
        _ -> :ok
      end
    end)

    :ok
  end

  @doc "Emits one stored history entry, preserving nested multiline structure."
  @spec replay(ChatHistory.t(), User.t()) :: :ok
  def replay(%ChatHistory{message: %{kind: :multiline} = multiline, msgid: msgid, occurred_at: occurred_at}, user) do
    timestamp = occurred_at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    if "batch" in user.capabilities and "draft/multiline" in user.capabilities do
      tags = multiline.tags |> Map.put("msgid", msgid) |> Map.put("time", timestamp)

      ResponseContext.with_batch("draft/multiline", [multiline.target], tags, fn ->
        Enum.each(multiline.lines, &Dispatcher.enqueue_prepared_message(&1, user))
      end)
    else
      replay_multiline_fallback(multiline, msgid, timestamp, user)
    end
  end

  def replay(%ChatHistory{message: %Message{} = message}, user), do: Dispatcher.broadcast(message, nil, user)

  defp replay_multiline_fallback(multiline, msgid, timestamp, user) do
    multiline.lines
    |> Enum.reject(&((&1.trailing || "") == ""))
    |> Enum.with_index()
    |> Enum.each(fn {message, index} ->
      tags =
        message.tags
        |> Map.drop(["batch", "draft/multiline-concat", "label", "msgid", "time"])
        |> Map.merge(Map.drop(multiline.tags, ["batch", "label", "msgid", "time"]))
        |> Map.put("time", timestamp)

      tags = if index == 0, do: Map.put(tags, "msgid", msgid), else: tags
      %{message | tags: tags} |> Dispatcher.enqueue_prepared_message(user)
    end)
  end

  defp do_record(message, sender) do
    if enabled?() and persist_message?(message) do
      with msgid when is_binary(msgid) <- message.tags["msgid"],
           {:ok, occurred_at, _offset} <- DateTime.from_iso8601(message.tags["time"]),
           {:ok, target} <- storage_target(sender, List.first(message.params)) do
        id = {target.key, DateTime.to_unix(occurred_at, :microsecond), msgid}

        HistoryRepository.create(%{
          id: id,
          target_type: target.type,
          target_key: target.key,
          target_name: target.name,
          msgid: msgid,
          sender_account_key: identity_key(sender),
          recipient_account_key: target[:recipient_account_key],
          message: message,
          occurred_at: occurred_at
        })

        prune_target(target.key, occurred_at)
        Observability.defer([:history], %{count: 1}, %{operation: :write_message})
      else
        _ -> :ok
      end
    end

    :ok
  end

  defp do_record_remote(message, sender_identity, recipient_identity, target_name, direction) do
    if enabled?() and persist_message?(message) and message.command in @message_commands do
      with true <- is_binary(sender_identity) and is_binary(recipient_identity),
           msgid when is_binary(msgid) <- message.tags["msgid"],
           timestamp when is_binary(timestamp) <- message.tags["time"],
           {:ok, occurred_at, _offset} <- DateTime.from_iso8601(timestamp) do
        target_key = direct_key(sender_identity, recipient_identity)

        HistoryRepository.create(%{
          id: {target_key, DateTime.to_unix(occurred_at, :microsecond), msgid},
          target_type: :direct,
          target_key: target_key,
          target_name: target_name,
          msgid: msgid,
          sender_account_key: sender_identity,
          recipient_account_key: recipient_identity,
          message: message,
          occurred_at: occurred_at
        })

        prune_target(target_key, occurred_at)
        Observability.defer([:history], %{count: 1}, %{operation: :write_remote_direct, direction: direction})
      else
        _ -> :ok
      end
    end

    :ok
  end

  @doc "Resolves and authorizes a target for a CHATHISTORY request."
  @spec target_for_request(User.t(), String.t()) :: {:ok, map()} | {:error, :invalid_target}
  def target_for_request(%User{} = user, target_name) do
    if channel_name?(target_name) do
      channel_key = CaseMapping.normalize(strip_status_prefix(target_name))

      case UserChannels.get_by_user_pid_and_channel_name(
             user.pid,
             strip_status_prefix(target_name)
           ) do
        {:ok, _membership} -> {:ok, %{type: :channel, key: "channel:" <> channel_key, name: target_name}}
        _ -> {:error, :invalid_target}
      end
    else
      with {:ok, target_identity} <- resolve_request_identity(target_name),
           requester_identity when is_binary(requester_identity) <- identity_key(user) do
        key = direct_key(requester_identity, target_identity)
        {:ok, %{type: :direct, key: key, name: target_name}}
      else
        _ -> {:error, :invalid_target}
      end
    end
  end

  @doc "Selects visible, non-redacted entries according to a CHATHISTORY subcommand."
  @spec query(String.t(), String.t(), history_reference(), history_reference() | nil, pos_integer(), boolean()) :: [
          ChatHistory.t()
        ]
  def query(target_key, subcommand, first_reference, second_reference, limit, include_events? \\ true) do
    started = System.monotonic_time()
    cutoff = retention_cutoff(DateTime.utc_now())

    entries =
      target_key
      |> HistoryRepository.for_target()
      |> Enum.reject(&(DateTime.compare(&1.occurred_at, cutoff) == :lt))

    first_reference = normalize_reference(entries, first_reference)
    second_reference = normalize_reference(entries, second_reference)
    entries = Enum.filter(entries, &(is_nil(&1.redacted_at) and (include_events? or not event?(&1))))

    result =
      case subcommand do
        "LATEST" -> latest(entries, first_reference, limit)
        "BEFORE" -> entries |> before(first_reference) |> take_last(limit)
        "AFTER" -> entries |> after_reference(first_reference) |> Enum.take(limit)
        "BETWEEN" -> between(entries, first_reference, second_reference, limit)
        "AROUND" -> around(entries, first_reference, limit)
      end

    Observability.defer([:history], %{count: 1, duration: System.monotonic_time() - started, rows: length(result)}, %{
      operation: :query
    })

    result
  end

  @doc "Lists the latest visible activity per history target inside an exclusive time window."
  @spec targets_for_request(User.t(), history_reference(), history_reference(), pos_integer()) :: [
          {String.t(), DateTime.t()}
        ]
  def targets_for_request(%User{} = user, lower, upper, limit) do
    requester_identity = identity_key(user)
    cutoff = retention_cutoff(DateTime.utc_now())
    reverse? = compare_reference_values(lower, upper) == :gt
    {earlier, later} = if reverse?, do: {upper, lower}, else: {lower, upper}

    channel_entries =
      user.pid
      |> UserChannels.get_by_user_pid()
      |> Enum.map(fn membership -> "channel:" <> membership.channel_name_key end)
      |> Enum.flat_map(&HistoryRepository.for_target/1)

    direct_entries = if is_binary(requester_identity), do: HistoryRepository.for_identity(requester_identity), else: []

    (channel_entries ++ direct_entries)
    |> Enum.reject(&(not is_nil(&1.redacted_at) or DateTime.compare(&1.occurred_at, cutoff) == :lt))
    |> Enum.filter(&target_visible_to?(&1, user, requester_identity))
    |> Enum.group_by(& &1.target_key)
    |> Enum.map(fn {_key, entries} -> Enum.max_by(entries, & &1.id) end)
    |> Enum.filter(&(after_bound?(&1, earlier) and before_bound?(&1, later)))
    |> Enum.sort_by(fn entry -> {DateTime.to_unix(entry.occurred_at, :microsecond), entry.msgid} end)
    |> then(fn entries ->
      if reverse?, do: Enum.take(entries, -limit), else: Enum.take(entries, limit)
    end)
    |> Enum.map(&{target_name_for(&1, requester_identity), &1.occurred_at})
  end

  @doc "Whether an entry is a non-message event requiring event-playback."
  @spec event?(ChatHistory.t()) :: boolean()
  def event?(%ChatHistory{message: %Message{command: command}}), do: command in @playback_event_commands
  def event?(%ChatHistory{}), do: false

  @doc "Parses the IRCv3 msgid/timestamp/* reference syntax."
  @spec parse_reference(String.t()) :: {:ok, history_reference()} | {:error, :invalid_reference}
  def parse_reference("*"), do: {:ok, :all}
  def parse_reference("msgid=" <> msgid) when msgid != "", do: {:ok, {:msgid, msgid}}

  def parse_reference("timestamp=" <> timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> {:ok, {:timestamp, datetime}}
      _ -> {:error, :invalid_reference}
    end
  end

  def parse_reference(_reference), do: {:error, :invalid_reference}

  @spec storage_target(User.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  defp storage_target(_sender, nil), do: {:error, :invalid_target}

  defp storage_target(sender, target_name) do
    bare_target = strip_status_prefix(target_name)

    if channel_name?(bare_target) do
      {:ok,
       %{
         type: :channel,
         key: "channel:" <> CaseMapping.normalize(bare_target),
         name: bare_target,
         recipient_account_key: nil
       }}
    else
      with {:ok, target_identity} <- resolve_identity(bare_target),
           sender_identity when is_binary(sender_identity) <- identity_key(sender) do
        {:ok,
         %{
           type: :direct,
           key: direct_key(sender_identity, target_identity),
           name: bare_target,
           recipient_account_key: target_identity
         }}
      else
        _ -> {:error, :invalid_target}
      end
    end
  end

  @spec resolve_identity(String.t()) :: {:ok, String.t()} | {:error, atom()}
  defp resolve_identity(nickname) do
    case Users.get_by_nick(nickname) do
      {:ok, user} -> {:ok, identity_key(user)}
      {:error, :user_not_found} -> resolve_registered_identity(nickname)
    end
  end

  defp resolve_request_identity(nickname) do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      case Directory.lookup_by_nick(nickname) do
        {:ok, remote} ->
          {:ok, remote_identity_key(%RemoteIdentity{origin: remote.origin, uid: remote.uid, nick: remote.user["nick"]})}

        :error ->
          resolve_identity(nickname)

        :unavailable ->
          {:error, :identity_not_found}
      end
    else
      resolve_identity(nickname)
    end
  end

  defp resolve_registered_identity(nickname) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} -> {:ok, "account:" <> CaseMapping.normalize(registered_nick.account_name)}
      _ -> {:error, :identity_not_found}
    end
  end

  @doc "Returns the non-reassignable identity used by persistent direct history and authorization."
  @spec identity_key(User.t()) :: String.t() | nil
  def identity_key(%User{identified_as: account}) when is_binary(account),
    do: "account:" <> CaseMapping.normalize(account)

  # Anonymous nicknames are recyclable. Binding their direct-message history to
  # the connection identity prevents a later registrant of the same nick from
  # inheriting a previous user's conversation.
  def identity_key(%User{pid: pid, nick: nick, created_at: created_at})
      when is_pid(pid) and is_binary(nick) do
    "session:" <> Base.url_encode64(:erlang.term_to_binary({pid, created_at}), padding: false)
  end

  def identity_key(_user), do: nil

  @doc "Returns a remote session identity that cannot alias a local account or nickname."
  @spec remote_identity_key(RemoteIdentity.t()) :: String.t()
  def remote_identity_key(%RemoteIdentity{origin: origin, uid: uid}), do: "remote:" <> origin <> ":" <> uid

  @spec direct_key(String.t(), String.t()) :: String.t()
  defp direct_key(left, right), do: "direct:" <> Enum.join(Enum.sort([left, right]), "\0")

  @spec strip_status_prefix(String.t()) :: String.t()
  defp strip_status_prefix(<<prefix, rest::binary>>) when prefix in [?@, ?+], do: rest
  defp strip_status_prefix(target), do: target

  @spec persist_message?(Message.t()) :: boolean()
  defp persist_message?(%Message{command: "TAGMSG", tags: tags}), do: Map.has_key?(tags, "+draft/persist")
  defp persist_message?(_message), do: true

  defp target_visible_to?(%ChatHistory{target_type: :channel, target_name: target}, user, _identity) do
    match?(
      {:ok, _membership},
      UserChannels.get_by_user_pid_and_channel_name(user.pid, target)
    )
  end

  defp target_visible_to?(%ChatHistory{target_type: :direct} = entry, _user, identity) when is_binary(identity) do
    entry.sender_account_key == identity or entry.recipient_account_key == identity
  end

  defp after_bound?(_entry, :all), do: true
  defp after_bound?(entry, reference), do: compare_reference(entry, reference) == :gt

  defp before_bound?(_entry, :all), do: true
  defp before_bound?(entry, reference), do: compare_reference(entry, reference) == :lt

  defp target_name_for(%ChatHistory{target_type: :channel, target_name: name}, _identity), do: name

  defp target_name_for(%ChatHistory{sender_account_key: identity, target_name: name}, identity), do: name

  defp target_name_for(%ChatHistory{message: %Message{prefix: prefix}}, _identity) when is_binary(prefix) do
    prefix |> String.split("!", parts: 2) |> hd()
  end

  defp target_name_for(%ChatHistory{message: %{kind: :multiline, lines: [%Message{prefix: prefix} | _]}}, _identity)
       when is_binary(prefix) do
    prefix |> String.split("!", parts: 2) |> hd()
  end

  defp target_name_for(%ChatHistory{target_name: name}, _identity), do: name

  @spec prune_target(String.t(), DateTime.t()) :: :ok
  defp prune_target(target_key, now) do
    config = Application.fetch_env!(:elixircd, :history)
    cutoff = retention_cutoff(now)

    retained =
      target_key
      |> HistoryRepository.for_target()
      |> Enum.reject(fn entry ->
        expired? = DateTime.compare(entry.occurred_at, cutoff) == :lt
        if expired?, do: HistoryRepository.delete(entry)
        expired?
      end)

    retained
    |> Enum.drop(-config[:max_entries_per_target])
    |> Enum.each(&HistoryRepository.delete/1)

    :ok
  end

  defp latest(entries, :all, limit), do: take_last(entries, limit)
  defp latest(entries, reference, limit), do: entries |> after_reference(reference) |> take_last(limit)

  defp before(entries, reference), do: Enum.filter(entries, &(compare_reference(&1, reference) == :lt))
  defp after_reference(entries, reference), do: Enum.filter(entries, &(compare_reference(&1, reference) == :gt))

  defp between(entries, first, second, limit) do
    case compare_references(entries, first, second) do
      :lt ->
        entries
        |> Enum.filter(&(compare_reference(&1, first) == :gt and compare_reference(&1, second) == :lt))
        |> Enum.take(limit)

      :gt ->
        entries
        |> Enum.filter(&(compare_reference(&1, second) == :gt and compare_reference(&1, first) == :lt))
        |> take_last(limit)

      :eq ->
        []
    end
  end

  defp around(_entries, :missing, _limit), do: []

  defp around(entries, reference, limit) do
    index = Enum.find_index(entries, &(compare_reference(&1, reference) in [:eq, :gt]))

    case index do
      nil ->
        take_last(entries, limit)

      index ->
        before_count = div(limit - 1, 2)
        start = max(index - before_count, 0)
        start = min(start, max(length(entries) - limit, 0))
        Enum.slice(entries, start, limit)
    end
  end

  defp compare_references(entries, first, second) do
    first_entry = Enum.find(entries, &(compare_reference(&1, first) == :eq))
    second_entry = Enum.find(entries, &(compare_reference(&1, second) == :eq))

    case {first_entry, second_entry} do
      {%ChatHistory{} = left, %ChatHistory{} = right} -> compare_ids(left.id, right.id)
      _ -> compare_reference_values(first, second)
    end
  end

  defp compare_reference(%ChatHistory{occurred_at: timestamp}, {:timestamp, reference}),
    do: DateTime.compare(timestamp, reference)

  defp compare_reference(%ChatHistory{id: id}, {:cursor, reference}), do: compare_ids(id, reference)

  defp compare_reference(_entry, :all), do: :gt
  defp compare_reference(_entry, :missing), do: :unrelated

  defp compare_reference_values({:timestamp, left}, {:timestamp, right}), do: DateTime.compare(left, right)
  defp compare_reference_values({:cursor, left}, {:cursor, right}), do: compare_ids(left, right)
  defp compare_reference_values(_left, _right), do: :eq

  defp normalize_reference(_entries, nil), do: nil
  defp normalize_reference(_entries, :all), do: :all
  defp normalize_reference(_entries, {:timestamp, _datetime} = reference), do: reference

  defp normalize_reference(entries, {:msgid, msgid}) do
    case Enum.find(entries, &(&1.msgid == msgid)) do
      nil -> :missing
      entry -> {:cursor, entry.id}
    end
  end

  defp compare_ids(left, right) when left < right, do: :lt
  defp compare_ids(left, right) when left > right, do: :gt
  defp compare_ids(_left, _right), do: :eq

  defp retention_cutoff(now) do
    DateTime.add(now, -Application.fetch_env!(:elixircd, :history)[:retention_seconds], :second)
  end

  @doc "Deletes expired entries, including targets with no new writes."
  @spec prune_expired(DateTime.t()) :: non_neg_integer()
  def prune_expired(now \\ DateTime.utc_now()) do
    cutoff = retention_cutoff(now)

    count =
      transactional(fn ->
        HistoryRepository.expired(cutoff)
        |> Enum.map(&HistoryRepository.delete/1)
        |> length()
      end)

    Observability.defer([:history], %{count: 1, rows: count}, %{operation: :prune})
    count
  end

  defp take_last(entries, limit), do: Enum.take(entries, -limit)

  defp transactional(fun) do
    if :mnesia.is_transaction(), do: fun.(), else: Memento.transaction!(fun)
  end
end
