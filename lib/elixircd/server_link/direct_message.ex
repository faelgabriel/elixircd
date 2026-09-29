defmodule ElixIRCd.ServerLink.DirectMessage do
  @moduledoc "Delivers authenticated remote private messages to real local connections."

  alias ElixIRCd.History.RemoteIdentity
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.UserAcceptRemotes
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Repositories.UserSilences
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.MessageText
  alias ElixIRCd.Utils.Protocol

  defmodule Outbound do
    @moduledoc "A local client's direct message awaiting its committed UID."

    @enforce_keys [:sender_pid, :target_origin, :target_uid, :target_nick, :command, :text, :tags]
    defstruct [:sender_pid, :target_origin, :target_uid, :target_nick, :command, :text, :tags]

    @type t :: %__MODULE__{
            sender_pid: pid(),
            target_origin: String.t(),
            target_uid: String.t(),
            target_nick: String.t(),
            command: String.t(),
            text: String.t(),
            tags: Message.tags()
          }
  end

  defmodule Pending do
    @moduledoc "A typed local direct message awaiting its recipient home's decision before source-side effects."

    @enforce_keys [
      :uid,
      :authority,
      :authority_epoch,
      :target_uid,
      :target_nick,
      :id,
      :sent_at,
      :sender,
      :command,
      :text,
      :tags
    ]
    defstruct [
      :uid,
      :authority,
      :authority_epoch,
      :target_uid,
      :target_nick,
      :id,
      :sent_at,
      :sender,
      :command,
      :text,
      :tags
    ]

    @type t :: %__MODULE__{
            uid: String.t(),
            authority: String.t(),
            authority_epoch: String.t(),
            target_uid: String.t(),
            target_nick: String.t(),
            id: String.t(),
            sent_at: String.t(),
            sender: User.t(),
            command: String.t(),
            text: String.t(),
            tags: Message.tags()
          }
  end

  defmodule Accepted do
    @moduledoc "A recipient home's accepted message and its current away text."

    @enforce_keys [:away]
    defstruct [:away]

    @type t :: %__MODULE__{away: String.t() | nil}
  end

  @doc "Checks local recipient policy and emits one IRC message without a fabricated sender PID."
  @type delivery_error :: :unknown_target | :registered_only | :accept_only | :silent

  @spec deliver(GenServer.server(), map(), map()) :: {:ok, Accepted.t()} | {:error, delivery_error()}
  def deliver(projector, sender, frame) do
    case Projector.pid_for_uid(projector, frame["to_uid"]) do
      {:ok, pid} -> deliver_to_pid(pid, sender, frame)
      :error -> {:error, :unknown_target}
    end
  end

  defp deliver_to_pid(pid, sender, frame) do
    case allowed_target(pid, sender, frame) do
      {:ok, target} ->
        message = %Message{
          command: frame["command"],
          params: [target.nick],
          trailing: frame["text"],
          tags: Map.merge(frame["tags"], %{"msgid" => frame["id"], "time" => frame["sent_at"]}),
          prefix: sender |> UserPayload.public_view() |> Protocol.user_mask()
        }

        remote = %RemoteIdentity{origin: frame["origin"], uid: frame["from_uid"], nick: sender["nick"]}
        Dispatcher.broadcast_remote_direct(message, remote, target)
        {:ok, %Accepted{away: target.away_message}}

      :blocked ->
        {:error, :silent}

      :missing ->
        {:error, :unknown_target}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Encodes the recipient home's closed direct-message result vocabulary."
  @spec result_code({:ok, Accepted.t()} | {:error, delivery_error()}) :: String.t()
  def result_code({:ok, %Accepted{}}), do: "ok"
  def result_code({:error, reason}), do: Atom.to_string(reason)

  @doc "Carries current away text only for a message accepted at the recipient home."
  @spec result_away({:ok, Accepted.t()} | {:error, delivery_error()}) :: String.t() | nil
  def result_away({:ok, %Accepted{away: away}}), do: away
  def result_away({:error, _reason}), do: nil

  @doc "Decodes a result that has already passed wire validation."
  @spec result_reason(String.t()) :: :ok | delivery_error()
  def result_reason("ok"), do: :ok
  def result_reason("unknown_target"), do: :unknown_target
  def result_reason("registered_only"), do: :registered_only
  def result_reason("accept_only"), do: :accept_only
  def result_reason("silent"), do: :silent

  @doc "Queues a local user's remote private message after its observed transaction commits."
  @spec send_from_local(User.t(), map(), String.t(), String.t(), Message.tags()) :: :ok
  def send_from_local(user, remote, command, message_text, message_tags) do
    if ElixIRCd.Multiline.collecting?() do
      # The batch validator requires a collected delivery record for every line.
      # Without a network-wide multiline envelope, do not leak partial lines.
      :ok
    else
      queue_from_local(user, remote, command, message_text, message_tags)
    end
  end

  defp queue_from_local(user, remote, command, message_text, message_tags) do
    tags =
      if "message-tags" in user.capabilities,
        do: Map.filter(message_tags, fn {key, _value} -> String.starts_with?(key, "+") end),
        else: %{}

    outbound = %Outbound{
      sender_pid: user.pid,
      target_origin: remote.origin,
      target_uid: remote.uid,
      target_nick: remote.user["nick"],
      command: command,
      text: message_text,
      tags: tags
    }

    Observability.defer_effect(fn ->
      if Hub.send_direct(outbound) == :unavailable, do: reply(user.pid, outbound.target_nick, :unavailable, command)
    end)
  end

  @doc "Echoes an accepted remote delivery and records its authenticated recipient UID."
  @spec accepted(pid(), Pending.t()) :: :ok
  def accepted(pid, %Pending{sender: %User{} = sender} = pending) do
    case Memento.transaction!(fn -> Users.get_by_pid(pid) end) do
      {:ok, %{registered: true}} ->
        remote = %RemoteIdentity{origin: pending.authority, uid: pending.target_uid, nick: pending.target_nick}

        %Message{command: pending.command, params: [pending.target_nick], trailing: pending.text, tags: pending.tags}
        |> Dispatcher.broadcast_with_echo_remote_history(sender, remote, pending.id, pending.sent_at)

      _ ->
        :ok
    end
  end

  @doc "Reports failed PRIVMSG delivery to its real local sender; NOTICE remains silent."
  @spec reply(pid(), String.t(), :ok | delivery_error() | :unavailable, String.t()) :: :ok
  def reply(_pid, _target_nick, _code, "NOTICE"), do: :ok
  def reply(_pid, _target_nick, :ok, _command), do: :ok
  def reply(_pid, _target_nick, :silent, _command), do: :ok

  def reply(pid, target_nick, code, "PRIVMSG") do
    case Memento.transaction!(fn -> Users.get_by_pid(pid) end) do
      {:ok, %{registered: true} = user} ->
        message =
          case code do
            :unknown_target ->
              %Message{command: :err_nosuchnick, params: [user.nick, target_nick], trailing: "No such nick"}

            :unavailable ->
              %Message{
                command: :err_unavailresource,
                params: [user.nick, target_nick],
                trailing: "User is temporarily unavailable on this network"
              }

            :registered_only ->
              %Message{
                command: :err_needreggednick,
                params: [user.nick, target_nick],
                trailing: "You must be identified to message this user"
              }

            :accept_only ->
              %Message{
                command: :rpl_umodegmsg,
                params: [user.nick, target_nick],
                trailing:
                  "Your message has been blocked. #{target_nick} is only accepting messages from authorized users."
              }
          end

        Dispatcher.broadcast_without_history(message, :server, user)

      _ ->
        :ok
    end
  end

  @doc "Returns an away reply only after the destination home accepts the PRIVMSG."
  @spec away_reply(pid(), String.t(), String.t() | nil) :: :ok
  def away_reply(_pid, _target_nick, nil), do: :ok

  def away_reply(pid, target_nick, away) do
    case Memento.transaction!(fn -> Users.get_by_pid(pid) end) do
      {:ok, %{registered: true} = user} ->
        %Message{command: :rpl_away, params: [user.nick, target_nick], trailing: away}
        |> Dispatcher.broadcast_without_history(:server, user)

      _ ->
        :ok
    end
  end

  defp allowed_target(pid, sender, frame) do
    Memento.transaction!(fn ->
      case Users.get_by_pid(pid) do
        {:ok, %{registered: true} = target} ->
          allowed_target_user(target, sender, frame)

        _ ->
          :missing
      end
    end)
  end

  defp allowed_target_user(target, sender, frame) do
    source = UserPayload.public_view(sender)

    cond do
      silent_for_target?(target, source, frame) ->
        :blocked

      :R in target.modes and :r not in source.modes ->
        {:error, :registered_only}

      :g in target.modes and
          is_nil(UserAcceptRemotes.get_by_user_pid_and_identity(target.pid, {frame["origin"], frame["from_uid"]})) ->
        {:error, :accept_only}

      true ->
        {:ok, target}
    end
  end

  defp silent_for_target?(target, source, frame) do
    Enum.any?(UserSilences.get_by_user_pid(target.pid), &Protocol.match_user_mask?(source, &1.mask)) or
      (:T in target.modes and MessageText.ctcp_message?(frame["text"]) and
         not MessageText.ctcp_action?(frame["text"]))
  end
end
