defmodule ElixIRCd.Metadata do
  @moduledoc "IRCv3 metadata policy, persistence, synchronization and notification."

  import ElixIRCd.Utils.Protocol, only: [channel_operator?: 1, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.Metadata, as: MetadataRepository
  alias ElixIRCd.Repositories.MetadataSubscriptions
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.Metadata, as: MetadataEntry
  alias ElixIRCd.Tables.User

  @capabilities ["draft/metadata-2", "draft/metadata-3"]
  @key_pattern ~r/\A[a-z0-9_.\/-]+\z/

  @type target :: %{
          type: :account | :channel | :session,
          key: String.t(),
          name: String.t(),
          entity: User.t() | Channel.t()
        }

  @doc "Reports whether metadata support is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.fetch_env!(:elixircd, :metadata)[:enabled]

  @doc "Reports whether a user negotiated a supported metadata capability."
  @spec capable?(User.t()) :: boolean()
  def capable?(%User{capabilities: capabilities}), do: Enum.any?(@capabilities, &(&1 in capabilities))

  @doc "Validates a metadata key against the wire grammar and size bound."
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key), do: is_binary(key) and byte_size(key) <= 64 and Regex.match?(@key_pattern, key)

  @doc "Validates a metadata value against UTF-8, framing and configured size bounds."
  @spec valid_value?(term()) :: boolean()
  def valid_value?(value) do
    is_binary(value) and String.valid?(value) and
      byte_size(value) <= Application.fetch_env!(:elixircd, :metadata)[:max_value_bytes] and
      not String.contains?(value, ["\r", "\n", <<0>>])
  end

  @doc "Returns the configured metadata-key limit per target."
  @spec max_keys() :: pos_integer()
  def max_keys, do: Application.fetch_env!(:elixircd, :metadata)[:max_keys]

  @doc "Returns the configured subscription limit per connection."
  @spec max_subscriptions() :: pos_integer()
  def max_subscriptions, do: Application.fetch_env!(:elixircd, :metadata)[:max_subscriptions]

  @doc "Resolves a wire target and enforces its read visibility."
  @spec resolve_target(User.t(), String.t()) :: {:ok, target()} | {:error, atom()}
  def resolve_target(user, "*"), do: {:ok, user_target(user)}

  def resolve_target(user, "#" <> _rest = channel_name), do: resolve_channel_target(user, channel_name)
  def resolve_target(user, "&" <> _rest = channel_name), do: resolve_channel_target(user, channel_name)

  def resolve_target(_user, nickname) do
    case Users.get_by_nick(nickname) do
      {:ok, %User{registered: true} = target_user} -> {:ok, user_target(target_user)}
      _ -> {:error, :invalid_target}
    end
  end

  defp resolve_channel_target(user, channel_name) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} ->
        if readable_channel?(user, channel),
          do: {:ok, channel_target(channel)},
          else: {:error, :no_permission}

      _ ->
        {:error, :invalid_target}
    end
  end

  defp readable_channel?(user, channel) do
    private? = Enum.any?(channel.modes, &mode_in?(&1, [:i, :p, :s]))

    not private? or irc_operator?(user) or
      match?({:ok, _}, UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name))
  end

  defp mode_in?({mode, _value}, modes), do: mode in modes
  defp mode_in?(mode, modes), do: mode in modes

  @doc "Reports whether a user may modify the resolved target."
  @spec writable?(User.t(), target()) :: boolean()
  def writable?(user, %{entity: %User{pid: pid}}), do: user.pid == pid or irc_operator?(user)

  def writable?(user, %{entity: %Channel{name: name}}) do
    irc_operator?(user) or
      case UserChannels.get_by_user_pid_and_channel_name(user.pid, name) do
        {:ok, membership} -> channel_operator?(membership)
        _ -> false
      end
  end

  @doc "Fetches one metadata entry from a resolved target."
  @spec get(target(), String.t()) :: MetadataEntry.t() | nil
  def get(target, key), do: MetadataRepository.get(target.type, target.key, key)

  @doc "Lists a resolved target's metadata entries."
  @spec list(target()) :: [MetadataEntry.t()]
  def list(target), do: MetadataRepository.list(target.type, target.key)

  @doc "Stores a metadata value and notifies authorized subscribers."
  @spec put(target(), String.t(), String.t()) :: MetadataEntry.t()
  def put(target, key, value) do
    result = MetadataRepository.put(target.type, target.key, key, value)
    notify(target, key, result)
    result
  end

  @doc "Deletes a metadata value and notifies authorized subscribers."
  @spec delete(target(), String.t()) :: MetadataEntry.t() | :not_found
  def delete(target, key) do
    case get(target, key) do
      nil ->
        :not_found

      entry ->
        MetadataRepository.delete(target.type, target.key, key)
        notify(target, key, nil)
        entry
    end
  end

  @doc "Clears all metadata values and notifies authorized subscribers."
  @spec clear(target()) :: [MetadataEntry.t()]
  def clear(target) do
    entries = MetadataRepository.clear(target.type, target.key)
    Enum.each(entries, &notify(target, &1.key, nil))
    entries
  end

  @doc "Subscribes a user connection to a metadata key."
  @spec subscribe(User.t(), String.t()) :: ElixIRCd.Tables.MetadataSubscription.t()
  def subscribe(user, key), do: MetadataSubscriptions.subscribe(user.pid, key)

  @doc "Unsubscribes a user connection from a metadata key."
  @spec unsubscribe(User.t(), String.t()) :: :ok
  def unsubscribe(user, key), do: MetadataSubscriptions.unsubscribe(user.pid, key)

  @doc "Lists a user connection's metadata subscriptions."
  @spec subscriptions(User.t()) :: [String.t()]
  def subscriptions(user), do: MetadataSubscriptions.list(user.pid)

  @doc "Counts the keys currently stored for a resolved target."
  @spec target_key_count(target()) :: non_neg_integer()
  def target_key_count(target), do: target |> list() |> length()

  @doc "Moves pre-authentication/session metadata to an authenticated account."
  @spec migrate_to_account(User.t()) :: :ok
  def migrate_to_account(%User{} = user) do
    if user.identified_as_key do
      MetadataRepository.migrate(:session, session_key(user), :account, user.identified_as_key)
    end

    :ok
  end

  @doc "Removes state that must not outlive an unauthenticated connection."
  @spec disconnect(User.t()) :: :ok
  def disconnect(%User{} = user) do
    MetadataSubscriptions.delete_by_user_pid(user.pid)

    unless user.identified_as_key do
      MetadataRepository.clear(:session, session_key(user))
    end

    :ok
  end

  @doc "Sends the required registration metadata batch, including an empty batch."
  @spec sync_registration(User.t()) :: :ok
  def sync_registration(%User{} = user) do
    if enabled?() and capable?(user) and "batch" in user.capabilities do
      migrate_to_account(user)
      target = user_target(user)

      ResponseContext.with_batch("metadata", [user.nick], fn ->
        Enum.each(list(target), &send_value(user, target.name, &1))
      end)
    end

    :ok
  end

  @doc "Synchronizes subscribed channel/member metadata to a joining user."
  @spec sync_join(User.t(), Channel.t(), [User.t()]) :: :ok
  def sync_join(%User{} = user, %Channel{} = channel, users) do
    if enabled?() and capable?(user) do
      subscriptions = MapSet.new(subscriptions(user))
      targets = [channel_target(channel) | Enum.map(users, &user_target/1)]

      Enum.each(targets, fn target ->
        target
        |> list()
        |> Enum.filter(&MapSet.member?(subscriptions, &1.key))
        |> Enum.each(&send_notification(user, target.name, &1.key, &1))
      end)
    end

    :ok
  end

  @doc "Synchronizes subscribed values for one resolved target."
  @spec sync_target(User.t(), target()) :: :ok
  def sync_target(user, target) do
    subscriptions = MapSet.new(subscriptions(user))

    ResponseContext.with_batch("metadata", [target.name], fn ->
      target
      |> list()
      |> Enum.filter(&MapSet.member?(subscriptions, &1.key))
      |> Enum.each(&send_metadata_message(user, target.name, &1))
    end)
  end

  @doc "Sends a metadata numeric containing a value."
  @spec send_value(User.t(), String.t(), MetadataEntry.t()) :: :ok
  def send_value(user, target_name, %MetadataEntry{} = entry) do
    %Message{
      command: "761",
      params: [reply_target(user), target_name, entry.key, entry.visibility],
      trailing: entry.value
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @doc "Sends a metadata numeric indicating that a key is unset."
  @spec send_not_set(User.t(), String.t(), String.t()) :: :ok
  def send_not_set(user, target_name, key) do
    %Message{command: "766", params: [reply_target(user), target_name, key], trailing: "key not set"}
    |> Dispatcher.broadcast(:server, user)
  end

  @doc "Builds metadata WHOIS numerics visible to the requester."
  @spec whois_messages(User.t(), User.t()) :: [Message.t()]
  def whois_messages(requester, target_user) do
    if capable?(requester) do
      target_user
      |> user_target()
      |> list()
      |> Enum.map(fn entry ->
        %Message{
          command: "760",
          params: [requester.nick, target_user.nick, entry.key, entry.visibility],
          trailing: entry.value
        }
      end)
    else
      []
    end
  end

  @doc "Migrates channel metadata after an atomic channel rename."
  @spec rename_channel(String.t(), String.t()) :: :ok
  def rename_channel(old_key, new_key), do: MetadataRepository.migrate(:channel, old_key, new_key)

  defp notify(target, key, entry) do
    key
    |> MetadataSubscriptions.subscribers()
    |> Users.get_by_pids()
    |> Enum.filter(&(capable?(&1) and receives_updates?(&1, target)))
    |> Enum.each(&send_notification(&1, target.name, key, entry))
  end

  defp receives_updates?(recipient, %{entity: %User{} = target_user}) do
    recipient.pid == target_user.pid or shared_channel?(recipient, target_user)
  end

  defp receives_updates?(recipient, %{entity: %Channel{name: name}}) do
    match?({:ok, _}, UserChannels.get_by_user_pid_and_channel_name(recipient.pid, name))
  end

  defp shared_channel?(left, right) do
    left_channels = left.pid |> UserChannels.get_by_user_pid() |> MapSet.new(& &1.channel_name_key)

    right.pid
    |> UserChannels.get_by_user_pid()
    |> Enum.any?(&MapSet.member?(left_channels, &1.channel_name_key))
  end

  defp send_notification(%User{capabilities: capabilities} = user, target_name, key, entry) do
    if "draft/metadata-2" in capabilities do
      if entry,
        do: send_metadata_message(user, target_name, entry),
        else: send_metadata_message(user, target_name, key)
    else
      if entry, do: send_value(user, target_name, entry), else: send_not_set(user, target_name, key)
    end
  end

  defp send_metadata_message(user, target_name, %MetadataEntry{} = entry) do
    %Message{command: "METADATA", params: [target_name, entry.key, entry.visibility], trailing: entry.value}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_metadata_message(user, target_name, key) do
    %Message{command: "METADATA", params: [target_name, key, "*"]}
    |> Dispatcher.broadcast(:server, user)
  end

  defp user_target(%User{} = user) do
    {type, key} = owner(user)
    %{type: type, key: key, name: user.nick || "*", entity: user}
  end

  defp channel_target(%Channel{} = channel),
    do: %{type: :channel, key: channel.name_key, name: channel.name, entity: channel}

  defp owner(%User{identified_as_key: key}) when is_binary(key), do: {:account, key}
  defp owner(%User{} = user), do: {:session, session_key(user)}

  defp session_key(%User{pid: pid}), do: pid |> :erlang.pid_to_list() |> to_string()
  defp reply_target(%User{nick: nil}), do: "*"
  defp reply_target(%User{nick: nick}), do: nick
end
