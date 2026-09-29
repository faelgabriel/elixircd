defmodule ElixIRCd.ServerLink.InviteMutation do
  @moduledoc "Applies a routed INVITE at the recipient home after checking channel membership and identity."

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.ChannelView.RemoteMember
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  defmodule Outbound do
    @moduledoc "A committed local INVITE addressed to a remote user UID."

    @enforce_keys [:sender_pid, :target_origin, :target_uid, :target_nick, :channel]
    defstruct [:sender_pid, :target_origin, :target_uid, :target_nick, :channel]

    @type t :: %__MODULE__{
            sender_pid: pid(),
            target_origin: String.t(),
            target_uid: String.t(),
            target_nick: String.t(),
            channel: String.t()
          }
  end

  defmodule LocalNotice do
    @moduledoc "A committed invitation between two local clients awaiting network announcement."

    alias ElixIRCd.ServerLink.InviteMutation.ChannelRef

    @enforce_keys [:sender_pid, :sender_mask, :sender_account, :target_pid, :target_nick, :channel, :channel_ref]
    defstruct [:sender_pid, :sender_mask, :sender_account, :target_pid, :target_nick, :channel, :channel_ref]

    @type t :: %__MODULE__{
            sender_pid: pid(),
            sender_mask: String.t(),
            sender_account: String.t() | nil,
            target_pid: pid(),
            target_nick: String.t(),
            channel: String.t(),
            channel_ref: ChannelRef.t()
          }
  end

  defmodule Request do
    @moduledoc "Authenticated remote inviter, local invitee UID and channel."

    @enforce_keys [:origin, :uid, :target_uid, :channel]
    defstruct [:origin, :uid, :target_uid, :channel]

    @type t :: %__MODULE__{origin: String.t(), uid: String.t(), target_uid: String.t(), channel: String.t()}
  end

  defmodule Pending do
    @moduledoc "A local INVITE awaiting the recipient home's decision."

    @enforce_keys [
      :uid,
      :sender_mask,
      :sender_account,
      :authority,
      :authority_epoch,
      :target_uid,
      :target_nick,
      :channel,
      :channel_ref
    ]
    defstruct [
      :uid,
      :sender_mask,
      :sender_account,
      :authority,
      :authority_epoch,
      :target_uid,
      :target_nick,
      :channel,
      :channel_ref
    ]

    @type t :: %__MODULE__{
            uid: String.t(),
            sender_mask: String.t(),
            sender_account: String.t() | nil,
            authority: String.t(),
            authority_epoch: String.t(),
            target_uid: String.t(),
            target_nick: String.t(),
            channel: String.t(),
            channel_ref: ElixIRCd.ServerLink.InviteMutation.ChannelRef.t()
          }
  end

  defmodule ChannelRef do
    @moduledoc "The selected creator and creation time at invitation dispatch."

    @enforce_keys [:creator, :created_at]
    defstruct [:creator, :created_at]

    @type t :: %__MODULE__{creator: String.t(), created_at: String.t()}
  end

  defmodule Notice do
    @moduledoc "An accepted invitation announced to channel members on other homes."

    alias ElixIRCd.ServerLink.InviteMutation.ChannelRef

    @enforce_keys [
      :origin,
      :epoch,
      :id,
      :uid,
      :sender_mask,
      :sender_account,
      :target_origin,
      :target_uid,
      :target_nick,
      :channel,
      :channel_ref,
      :ttl
    ]
    defstruct [
      :origin,
      :epoch,
      :id,
      :uid,
      :sender_mask,
      :sender_account,
      :target_origin,
      :target_uid,
      :target_nick,
      :channel,
      :channel_ref,
      :ttl
    ]

    @type t :: %__MODULE__{
            origin: String.t(),
            epoch: String.t(),
            id: String.t(),
            uid: String.t(),
            sender_mask: String.t(),
            sender_account: String.t() | nil,
            target_origin: String.t(),
            target_uid: String.t(),
            target_nick: String.t(),
            channel: String.t(),
            channel_ref: ChannelRef.t(),
            ttl: 1..64
          }
  end

  defmodule Accepted do
    @moduledoc "A committed invitation and the current away text of its recipient."

    @enforce_keys [:away]
    defstruct [:away]

    @type t :: %__MODULE__{away: String.t() | nil}
  end

  @type error ::
          :stale_channel
          | :unknown_sender
          | :not_on_channel
          | :operator_required
          | :unknown_target
          | :already_on_channel
          | :registered_channel

  @doc "Builds a typed request from a validated wire frame."
  @spec from_frame(map()) :: Request.t()
  def from_frame(frame) do
    %Request{origin: frame["origin"], uid: frame["from_uid"], target_uid: frame["to_uid"], channel: frame["channel"]}
  end

  @doc "Builds a typed accepted-invite notice from a validated wire frame."
  @spec notice_from_frame(map()) :: Notice.t()
  def notice_from_frame(frame) do
    %Notice{
      origin: frame["origin"],
      epoch: frame["epoch"],
      id: frame["id"],
      uid: frame["from_uid"],
      sender_mask: frame["from_mask"],
      sender_account: frame["from_account"],
      target_origin: frame["target_origin"],
      target_uid: frame["target_uid"],
      target_nick: frame["target_nick"],
      channel: frame["channel"],
      channel_ref: %ChannelRef{creator: frame["channel_creator"], created_at: frame["channel_created_at"]},
      ttl: frame["ttl"]
    }
  end

  @doc "Serializes the accepted invitation for an authenticated server link."
  @spec notice_frame(Notice.t()) :: map()
  def notice_frame(%Notice{} = notice) do
    %{
      "type" => "invite_notice",
      "origin" => notice.origin,
      "epoch" => notice.epoch,
      "id" => notice.id,
      "from_uid" => notice.uid,
      "from_mask" => notice.sender_mask,
      "from_account" => notice.sender_account,
      "target_origin" => notice.target_origin,
      "target_uid" => notice.target_uid,
      "target_nick" => notice.target_nick,
      "channel" => notice.channel,
      "channel_creator" => notice.channel_ref.creator,
      "channel_created_at" => notice.channel_ref.created_at,
      "ttl" => notice.ttl
    }
  end

  @doc "Delivers a remote notice only to local members of the same selected channel."
  @spec deliver_notice(Notice.t()) :: :ok
  def deliver_notice(%Notice{} = notice) do
    notify_local_members(
      notice.channel,
      notice.target_nick,
      notice.sender_mask,
      notice.sender_account,
      notice.channel_ref
    )

    :ok
  end

  @doc "Persists an invitation for one real local client and delivers it only after commit."
  @spec apply_remote(Request.t(), Replica.t(), ChannelView.t(), GenServer.server()) ::
          {:ok, Accepted.t()} | {:error, error()}
  def apply_remote(%Request{} = request, %Replica{} = replica, %ChannelView{} = view, projector) do
    case Projector.pid_for_uid(projector, request.target_uid) do
      {:ok, target_pid} ->
        Observability.transaction(fn -> apply_in_transaction(request, replica, view, target_pid) end)

      :error ->
        {:error, :unknown_target}
    end
  end

  @doc "Maps a recipient-home decision to the closed wire result."
  @spec result_code({:ok, Accepted.t()} | {:error, error()}) :: String.t()
  def result_code({:ok, %Accepted{}}), do: "ok"
  def result_code({:error, reason}), do: Atom.to_string(reason)

  @doc "Returns the accepted recipient's current AWAY text for the wire result."
  @spec result_away({:ok, Accepted.t()} | {:error, error()}) :: String.t() | nil
  def result_away({:ok, %Accepted{away: away}}), do: away
  def result_away({:error, _reason}), do: nil

  @doc "Reports an authenticated recipient-home result to the original inviter."
  @spec reply(pid(), String.t(), String.t(), String.t(), String.t() | nil, ChannelRef.t() | nil) :: :ok
  def reply(pid, channel, target_nick, code, away \\ nil, channel_ref \\ nil) do
    case Memento.transaction!(fn -> Users.get_by_pid(pid) end) do
      {:ok, %{registered: true} = inviter} ->
        send_reply(inviter, channel, target_nick, code, away, channel_ref)

      _ ->
        :ok
    end
  end

  defp send_reply(inviter, channel, target_nick, "ok", away, channel_ref) do
    if away do
      %Message{command: :rpl_away, params: [inviter.nick, target_nick], trailing: away}
      |> Dispatcher.broadcast_without_history(:server, inviter)
    end

    %Message{command: :rpl_inviting, params: [inviter.nick, target_nick, channel]}
    |> Dispatcher.broadcast_without_history(:server, inviter)

    notify_local_members(channel, target_nick, Protocol.user_mask(inviter), inviter.identified_as, channel_ref)
  end

  defp send_reply(inviter, channel, target_nick, code, _away, _channel_ref) do
    error = error_message(inviter.nick, channel, target_nick, code)
    Dispatcher.broadcast_without_history(error, :server, inviter)
  end

  defp error_message(nick, _channel, target, "unknown_target"),
    do: %Message{command: :err_nosuchnick, params: [nick, target], trailing: "No such nick/channel"}

  defp error_message(nick, channel, _target, "not_on_channel"),
    do: %Message{command: :err_notonchannel, params: [nick, channel], trailing: "You're not on that channel"}

  defp error_message(nick, channel, _target, "operator_required"),
    do: %Message{command: :err_chanoprivsneeded, params: [nick, channel], trailing: "You're not channel operator"}

  defp error_message(nick, channel, target, "already_on_channel"),
    do: %Message{command: :err_useronchannel, params: [nick, target, channel], trailing: "is already on channel"}

  defp error_message(nick, channel, _target, _code),
    do: %Message{
      command: :err_unavailresource,
      params: [nick, channel],
      trailing: "Channel invitations are temporarily unavailable on this network"
    }

  defp apply_in_transaction(request, replica, view, target_pid) do
    with :ok <- active_channel(request.channel, view),
         {:ok, sender} <- remote_sender(replica, request),
         {:ok, member} <- remote_member(view, request),
         :ok <- inviter_permission(view, member),
         :ok <- unregistered_channel(request.channel),
         {:ok, target} <- local_target(target_pid),
         :ok <- not_already_member(target, request.channel) do
      mask = sender |> UserPayload.public_view() |> Protocol.user_mask()

      existing_bypass =
        case ChannelInvites.get_by_user_pid_and_channel_name(target.pid, request.channel) do
          {:ok, invite} -> invite.bypass_ban == true
          {:error, :channel_invite_not_found} -> false
        end

      ChannelInvites.create(%{
        user_pid: target.pid,
        channel_name_key: CaseMapping.normalize(request.channel),
        setter: mask,
        bypass_ban: "o" in member.effective_modes or existing_bypass
      })

      notifiers = invite_notifiers(request.channel)

      Observability.defer_effect(fn ->
        deliver_invitation(target, request.channel, mask, sender["account"])
        deliver_notification(notifiers, request.channel, target.nick, mask, sender["account"])
      end)

      {:ok, %Accepted{away: target.away_message}}
    end
  end

  defp active_channel(name, view) do
    key = CaseMapping.normalize(name)
    selected = view.channel

    if CaseMapping.normalize(selected["name"]) == key and local_identity_aligned?(key, selected),
      do: :ok,
      else: {:error, :stale_channel}
  end

  defp local_identity_aligned?(key, selected) do
    case Channels.get_by_name(key) do
      {:ok, channel} ->
        local_id = Application.fetch_env!(:elixircd, :server)[:hostname]

        creator =
          case Memento.Query.read(ChannelIdentity, channel.name_key) do
            %ChannelIdentity{creator: creator} -> creator
            nil -> local_id
          end

        case DateTime.from_iso8601(selected["created_at"]) do
          {:ok, timestamp, _offset} ->
            creator == selected["creator"] and DateTime.compare(channel.created_at, timestamp) == :eq

          _ ->
            false
        end

      {:error, :channel_not_found} ->
        true
    end
  end

  defp remote_sender(replica, request) do
    case Replica.get_by_uid(replica, request.origin, request.uid) do
      {:ok, sender} -> {:ok, sender}
      :error -> {:error, :unknown_sender}
    end
  end

  defp remote_member(view, request) do
    case Enum.find(view.remote_members, fn member ->
           member.origin == request.origin and member.member["uid"] == request.uid and member.effective
         end) do
      %RemoteMember{} = member -> {:ok, member}
      nil -> {:error, :not_on_channel}
    end
  end

  defp inviter_permission(view, member) do
    invite_only = Enum.any?(view.channel["modes"], &(&1["name"] == "i"))
    if not invite_only or "o" in member.effective_modes, do: :ok, else: {:error, :operator_required}
  end

  defp unregistered_channel(name) do
    case RegisteredChannels.get_by_name(name) do
      {:ok, _registered} -> {:error, :registered_channel}
      {:error, :registered_channel_not_found} -> :ok
    end
  end

  defp local_target(pid) do
    case Users.get_by_pid(pid) do
      {:ok, %{registered: true} = target} -> {:ok, target}
      _ -> {:error, :unknown_target}
    end
  end

  defp not_already_member(target, channel) do
    case UserChannels.get_by_user_pid_and_channel_name(target.pid, channel) do
      {:ok, _membership} -> {:error, :already_on_channel}
      {:error, :user_channel_not_found} -> :ok
    end
  end

  defp deliver_invitation(target, channel, mask, account) do
    tags = if account, do: %{"account" => account}, else: %{}

    %Message{command: "INVITE", params: [target.nick, channel], prefix: mask, tags: tags}
    |> Dispatcher.broadcast_without_history(nil, target)
  end

  defp notify_local_members(channel_name, target_nick, mask, account, %ChannelRef{} = channel_ref) do
    with {:ok, %ChannelView{channel: selected}} <- ChannelDirectory.get(channel_name),
         true <- selected["creator"] == channel_ref.creator and selected["created_at"] == channel_ref.created_at do
      recipients = Memento.transaction!(fn -> current_notifiers(channel_name, selected) end)
      deliver_notification(recipients, channel_name, target_nick, mask, account)
    else
      _ -> :ok
    end
  end

  defp notify_local_members(_channel_name, _target_nick, _mask, _account, nil), do: :ok

  defp current_notifiers(channel_name, selected) do
    if local_identity_aligned?(CaseMapping.normalize(channel_name), selected),
      do: invite_notifiers(channel_name),
      else: []
  end

  defp invite_notifiers(channel_name) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} ->
        channel.name
        |> UserChannels.get_by_channel_name()
        |> Enum.map(& &1.user_pid)
        |> Users.get_by_pids()
        |> Enum.filter(&("invite-notify" in &1.capabilities))

      {:error, :channel_not_found} ->
        []
    end
  end

  defp deliver_notification(recipients, channel_name, target_nick, mask, account) do
    tags = if account, do: %{"account" => account}, else: %{}

    %Message{command: "INVITE", params: [target_nick, channel_name], prefix: mask, tags: tags}
    |> Dispatcher.broadcast_without_history(nil, recipients)
  end
end
