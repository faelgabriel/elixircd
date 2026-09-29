defmodule ElixIRCd.ServerLink.ChannelMessage do
  @moduledoc "Delivers authenticated remote channel messages to real local members."

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.MessageFilter
  alias ElixIRCd.Utils.MessageText
  alias ElixIRCd.Utils.Protocol
  alias ElixIRCd.Utils.Statusmsg

  defmodule Identity do
    @moduledoc "The creator and timestamp of one channel incarnation."

    @enforce_keys [:creator, :created_at]
    defstruct [:creator, :created_at]

    @type t :: %__MODULE__{creator: String.t(), created_at: String.t()}
  end

  defmodule LocalSelection do
    @moduledoc "The local channel with the selected network modes and its committed view."

    alias ElixIRCd.ServerLink.ChannelView
    alias ElixIRCd.Tables.Channel

    @enforce_keys [:channel, :view]
    defstruct [:channel, :view]

    @type t :: %__MODULE__{channel: Channel.t(), view: ChannelView.t() | nil}
  end

  defmodule MuteLists do
    @moduledoc "Effective local and remote mute bans and their exceptions."

    @enforce_keys [:bans, :excepts]
    defstruct [:bans, :excepts]

    @type t :: %__MODULE__{bans: [String.t()], excepts: [String.t()]}
  end

  defmodule LocalRecipients do
    @moduledoc "Local channel recipients and effective mute masks captured together."

    alias ElixIRCd.ServerLink.ChannelMessage.MuteLists
    alias ElixIRCd.Tables.Channel
    alias ElixIRCd.Tables.User
    alias ElixIRCd.Tables.UserChannel

    @enforce_keys [:channel, :memberships, :users, :mute_lists]
    defstruct [:channel, :memberships, :users, :mute_lists]

    @type t :: %__MODULE__{
            channel: Channel.t(),
            memberships: [UserChannel.t()],
            users: [User.t()],
            mute_lists: MuteLists.t()
          }
  end

  defmodule Outbound do
    @moduledoc "One local channel message awaiting final Hub acceptance."

    alias ElixIRCd.Message
    alias ElixIRCd.ServerLink.ChannelMessage.Identity

    @enforce_keys [:sender_pid, :channel, :target, :command, :text, :tags, :identity]
    defstruct [:sender_pid, :channel, :target, :command, :text, :tags, :identity, remote_only: false]

    @type t :: %__MODULE__{
            sender_pid: pid(),
            channel: String.t(),
            target: String.t(),
            command: String.t(),
            text: String.t(),
            tags: Message.tags(),
            identity: Identity.t(),
            remote_only: boolean()
          }
  end

  defmodule LocalDelivery do
    @moduledoc "The accepted sender, recipients and channel identity captured together."

    alias ElixIRCd.ServerLink.ChannelMessage.Identity
    alias ElixIRCd.Tables.User

    @enforce_keys [:sender, :recipients, :identity]
    defstruct [:sender, :recipients, :identity]

    @type t :: %__MODULE__{sender: User.t(), recipients: [User.t()], identity: Identity.t()}
  end

  @doc "Selects authoritative network modes for a local channel inside a Mnesia transaction."
  @spec select_local(Channel.t()) :: {:ok, LocalSelection.t()} | {:error, :network_directory_unavailable}
  def select_local(%Channel{} = channel) do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      case ChannelDirectory.get(channel.name) do
        {:ok, %ChannelView{} = view} -> select_aligned_local(channel, view)
        _ -> {:error, :network_directory_unavailable}
      end
    else
      {:ok, %LocalSelection{channel: channel, view: nil}}
    end
  end

  defp select_aligned_local(channel, view) do
    if same_identity?(local_identity(channel), payload_identity(view.channel)) do
      case ChannelPayload.to_local(view.channel) do
        {:ok, attrs} -> {:ok, %LocalSelection{channel: %{channel | modes: attrs.modes}, view: view}}
        _ -> {:error, :network_directory_unavailable}
      end
    else
      {:error, :network_directory_unavailable}
    end
  end

  @doc "Checks one local sender against the selected channel modes and mute lists."
  @spec check_local_permissions(
          Channel.t(),
          ChannelView.t() | nil,
          ElixIRCd.Tables.User.t(),
          ElixIRCd.Tables.UserChannel.t() | nil,
          String.t(),
          String.t()
        ) ::
          :ok | {:error, atom()} | {:error, :delay_message_blocked, integer()}
  def check_local_permissions(channel, view, user, membership, command, text) do
    with :ok <- check_membership(channel, membership),
         :ok <- check_local_mute(channel, view, user, membership),
         :ok <- MessageFilter.check_registered_only_speak(channel, user, membership),
         :ok <- check_ctcp(channel, membership, text),
         :ok <- check_formatting(channel, text) do
      check_notice(channel, membership, command)
    end
  end

  @doc "Captures final local recipients only if the current Hub view still accepts the message."
  @spec prepare_local(Outbound.t(), ChannelView.t()) ::
          {:ok, LocalDelivery.t()} | {:error, atom() | {:delay_message_blocked, integer()}}
  def prepare_local(%Outbound{} = outbound, %ChannelView{} = view) do
    with {:ok, user} <- Users.get_by_pid(outbound.sender_pid),
         true <- user.registered,
         {:ok, channel} <- Channels.get_by_name(outbound.channel),
         identity = local_identity(channel),
         true <- same_identity?(identity, outbound.identity),
         true <- same_identity?(identity, payload_identity(view.channel)),
         {:ok, attrs} <- ChannelPayload.to_local(view.channel),
         selected = %{channel | modes: attrs.modes},
         membership = local_membership(user.pid, channel.name),
         :ok <- check_local_permissions(selected, view, user, membership, outbound.command, outbound.text) do
      recipients =
        channel.name
        |> UserChannels.get_by_channel_name()
        |> Enum.reject(&(&1.user_pid == user.pid))
        |> filter_status_target(outbound.target, channel.name)
        |> MessageFilter.filter_op_moderated_users(membership, selected.modes)
        |> Enum.map(& &1.user_pid)
        |> Users.get_by_pids()

      {:ok, %LocalDelivery{sender: user, recipients: recipients, identity: identity}}
    else
      {:error, :user_not_found} -> {:error, :network_directory_unavailable}
      {:error, :channel_not_found} -> {:error, :network_directory_unavailable}
      false -> {:error, :network_directory_unavailable}
      {:error, :invalid_channel} -> {:error, :network_directory_unavailable}
      error -> error
    end
  end

  defp local_membership(user_pid, channel_name) do
    case UserChannels.get_by_user_pid_and_channel_name(user_pid, channel_name) do
      {:ok, membership} -> membership
      _ -> nil
    end
  end

  defp check_membership(channel, nil) do
    if :m in channel.modes or :n in channel.modes, do: {:error, :user_can_not_send}, else: :ok
  end

  defp check_membership(channel, membership) do
    if :m in channel.modes and not membership_privileged?(membership) do
      {:error, :user_can_not_send}
    else
      check_delay(channel, membership)
    end
  end

  defp check_delay(channel, membership) do
    case Enum.find_value(channel.modes, fn
           {:d, seconds} -> String.to_integer(seconds)
           _ -> nil
         end) do
      delay when is_integer(delay) ->
        elapsed = DateTime.diff(DateTime.utc_now(), membership.created_at)

        if membership_privileged?(membership) or elapsed >= delay,
          do: :ok,
          else: {:error, :delay_message_blocked, delay}

      nil ->
        :ok
    end
  end

  defp check_ctcp(channel, membership, text) do
    if :C in channel.modes and MessageText.ctcp_message?(text) and not MessageText.ctcp_action?(text) and
         not membership_privileged?(membership),
       do: {:error, :ctcp_blocked},
       else: :ok
  end

  defp check_formatting(channel, text) do
    if :c in channel.modes and MessageText.contains_formatting?(text),
      do: {:error, :formatting_blocked},
      else: :ok
  end

  defp check_notice(channel, membership, "NOTICE") do
    if :T in channel.modes and not membership_privileged?(membership),
      do: {:error, :notice_blocked},
      else: :ok
  end

  defp check_notice(_channel, _membership, _command), do: :ok

  @doc "Checks channel mute masks from local Mnesia and identity-matched remote contributions."
  @spec check_local_mute(
          Channel.t(),
          ChannelView.t() | nil,
          ElixIRCd.Tables.User.t(),
          ElixIRCd.Tables.UserChannel.t() | nil
        ) ::
          :ok | {:error, :user_muted}
  def check_local_mute(channel, view, user, membership) do
    if membership_privileged?(membership) or mute_allowed?(effective_mute_lists(channel, view), user) do
      :ok
    else
      {:error, :user_muted}
    end
  end

  @doc "Captures the identity of a local channel inside a Mnesia transaction."
  @spec local_identity(ElixIRCd.Tables.Channel.t()) :: Identity.t()
  def local_identity(channel) do
    local_id = Application.fetch_env!(:elixircd, :server)[:hostname]

    creator =
      case Memento.Query.read(ChannelIdentity, channel.name_key) do
        %ChannelIdentity{creator: creator} -> creator
        nil -> local_id
      end

    %Identity{creator: creator, created_at: DateTime.to_iso8601(channel.created_at)}
  end

  @doc "Checks that an incoming frame belongs to both the selected and the sender's contributed channel."
  @spec accepted_identity?(%{optional(String.t()) => ChannelView.t()}, Replica.t(), map()) :: boolean()
  def accepted_identity?(views, replica, frame) do
    key = CaseMapping.normalize(frame["channel"])

    with %ChannelView{} = view <- Map.get(views, key),
         {:ok, contributed} <- Map.fetch(replica.channels, {frame["origin"], key}) do
      same_identity?(frame_identity(frame), payload_identity(view.channel)) and
        same_identity?(payload_identity(contributed), payload_identity(view.channel))
    else
      _ -> false
    end
  end

  @doc "Checks two channel identities by creator and instant, independent of timestamp text format."
  @spec same_identity?(Identity.t(), Identity.t()) :: boolean()
  def same_identity?(%Identity{} = left, %Identity{} = right) do
    with {:ok, left_time, _} <- DateTime.from_iso8601(left.created_at),
         {:ok, right_time, _} <- DateTime.from_iso8601(right.created_at) do
      left.creator == right.creator and DateTime.compare(left_time, right_time) == :eq
    else
      _ -> false
    end
  end

  @doc "Builds a typed identity from validated channel metadata."
  @spec payload_identity(map()) :: Identity.t()
  def payload_identity(payload), do: %Identity{creator: payload["creator"], created_at: payload["created_at"]}

  @doc "Builds a typed identity from a validated channel message."
  @spec frame_identity(map()) :: Identity.t()
  def frame_identity(frame), do: %Identity{creator: frame["channel_creator"], created_at: frame["channel_created_at"]}

  @doc "Queues a checked local channel message after its Mnesia transaction commits."
  @spec queue_local(ElixIRCd.Tables.User.t(), Channel.t(), String.t(), String.t(), String.t(), Message.tags()) :: :ok
  def queue_local(user, channel, wire_target, command, text, message_tags) do
    outbound = %Outbound{
      sender_pid: user.pid,
      channel: channel.name,
      target: wire_target,
      command: command,
      text: text,
      tags: message_tags,
      identity: local_identity(channel),
      remote_only: ElixIRCd.Multiline.collecting?()
    }

    if outbound.remote_only do
      ElixIRCd.Multiline.collect_linked(outbound)
    else
      flush_local(user, [outbound])
    end
  end

  @doc "Queues validated multiline lines only after the complete local batch succeeds."
  @spec flush_local(ElixIRCd.Tables.User.t(), [Outbound.t()]) :: :ok
  def flush_local(user, outbounds) do
    Observability.defer_effect(fn ->
      Enum.each(outbounds, &flush_one(user, &1))
    end)
  end

  defp flush_one(user, outbound) do
    if Hub.send_channel(outbound) == :unavailable,
      do: reply_local_error(outbound, user, :network_directory_unavailable)
  end

  @doc "Queues one multiline channel line when links are enabled."
  @spec send_from_local(ElixIRCd.Tables.User.t(), String.t(), String.t(), String.t(), String.t(), Message.tags()) :: :ok
  def send_from_local(user, channel_name, wire_target, command, text, message_tags) do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      case Channels.get_by_name(channel_name) do
        {:ok, channel} -> queue_local(user, channel, wire_target, command, text, message_tags)
        _ -> :ok
      end
    else
      :ok
    end
  end

  @doc "Replies to a local PRIVMSG rejected by the Hub after source validation."
  @spec reply_local_error(Outbound.t(), ElixIRCd.Tables.User.t(), atom() | tuple()) :: :ok
  def reply_local_error(%Outbound{command: "NOTICE"}, _user, _reason), do: :ok

  def reply_local_error(%Outbound{} = outbound, user, reason) do
    {command, trailing} =
      case reason do
        :network_directory_unavailable ->
          {:err_unavailresource, "Channel state is temporarily unavailable on this network"}

        :registered_only_speak ->
          {:err_needreggednick, "You must be identified to speak in this channel (+M)"}

        :ctcp_blocked ->
          {:err_cannotsendtochan, "Cannot send CTCP to channel (+C)"}

        :formatting_blocked ->
          {:err_cannotsendtochan, "Cannot send to channel (+c - no colors allowed)"}

        {:delay_message_blocked, delay} ->
          {:err_delaymessageblocked, "You must wait #{delay} seconds after joining before speaking in this channel."}

        _ ->
          {:err_cannotsendtochan, "Cannot send to channel"}
      end

    %Message{command: command, params: [user.nick, outbound.channel], trailing: trailing}
    |> Dispatcher.broadcast(:server, user)
  end

  @doc "Checks the committed channel view and sends a remote PRIVMSG or NOTICE to local members."
  @spec deliver(map(), map(), map()) :: :ok
  def deliver(views, sender, frame) do
    key = CaseMapping.normalize(frame["channel"])

    with {:ok, %ChannelView{} = view} <- Map.fetch(views, key),
         true <- same_identity?(frame_identity(frame), payload_identity(view.channel)),
         {:ok, recipients} <- local_recipients(key, view),
         {:ok, recipients} <- allowed_recipients(view, sender, frame, recipients) do
      message = %Message{
        command: frame["command"],
        params: [frame["target"]],
        trailing: frame["text"],
        tags: frame["tags"],
        prefix: sender |> UserPayload.public_view() |> Protocol.user_mask()
      }

      Dispatcher.broadcast_without_history(message, nil, recipients)
    end

    :ok
  end

  defp local_recipients(key, view) do
    Memento.transaction!(fn ->
      with {:ok, channel} <- Channels.get_by_name(key),
           true <- same_identity?(local_identity(channel), payload_identity(view.channel)) do
        memberships = UserChannels.get_by_channel_name(channel.name)
        users = memberships |> Enum.map(& &1.user_pid) |> Users.get_by_pids()

        {:ok,
         %LocalRecipients{
           channel: channel,
           memberships: memberships,
           users: users,
           mute_lists: effective_mute_lists(channel, view)
         }}
      end
    end)
  end

  defp allowed_recipients(view, sender, frame, %LocalRecipients{} = local) do
    member =
      Enum.find(view.remote_members, fn entry ->
        entry.origin == frame["origin"] and entry.member["uid"] == frame["from_uid"]
      end)

    modes = Map.new(view.channel["modes"], &{&1["name"], &1["parameter"]})
    status = if member, do: member.effective_modes, else: []

    if sender_allowed?(modes, member, status, sender, frame, local.mute_lists) do
      selected =
        local.memberships
        |> filter_status_target(frame["target"], frame["channel"])
        |> filter_op_moderated(status, modes, local.channel.modes)
        |> MapSet.new(& &1.user_pid)

      {:ok, Enum.filter(local.users, &MapSet.member?(selected, &1.pid))}
    else
      :error
    end
  end

  defp sender_allowed?(modes, member, status, sender, frame, mute_lists) do
    privileged? = privileged?(status)

    membership_allowed?(modes, member, privileged?) and
      special_modes_allowed?(modes, sender, frame["command"], privileged?) and
      content_allowed?(modes, frame["text"], privileged?) and
      (privileged? or mute_allowed?(mute_lists, UserPayload.public_view(sender))) and
      not delayed?(modes["d"], member, privileged?)
  end

  defp mute_allowed?(%MuteLists{} = lists, sender) do
    muted? = Enum.any?(lists.bans, &Protocol.match_mute_mask?(sender, &1))
    excepted? = Enum.any?(lists.excepts, &Protocol.match_mute_mask?(sender, &1))
    not muted? or excepted?
  end

  defp effective_mute_lists(channel, view) do
    local_bans = Enum.map(ChannelBans.get_by_channel_name_key(channel.name_key), & &1.mask)
    local_excepts = Enum.map(ChannelExcepts.get_by_channel_name_key(channel.name_key), & &1.mask)

    %MuteLists{
      bans: local_bans ++ remote_mute_masks(view, "b"),
      excepts: local_excepts ++ remote_mute_masks(view, "e")
    }
  end

  defp remote_mute_masks(nil, _kind), do: []

  defp remote_mute_masks(%ChannelView{} = view, kind) do
    for record <- view.remote_lists,
        record.effective and record.entry["kind"] == kind,
        do: record.entry["mask"]
  end

  defp membership_privileged?(nil), do: false
  defp membership_privileged?(membership), do: :o in membership.modes or :v in membership.modes

  defp membership_allowed?(modes, member, privileged?) do
    (not is_nil(member) or (not Map.has_key?(modes, "n") and not Map.has_key?(modes, "m"))) and
      (not Map.has_key?(modes, "m") or privileged?)
  end

  defp special_modes_allowed?(modes, sender, command, privileged?) do
    (not Map.has_key?(modes, "M") or "r" in sender["modes"] or privileged?) and
      (not Map.has_key?(modes, "T") or command != "NOTICE" or privileged?)
  end

  defp content_allowed?(modes, text, privileged?) do
    (not Map.has_key?(modes, "C") or not blocked_ctcp?(text) or privileged?) and
      (not Map.has_key?(modes, "c") or not MessageText.contains_formatting?(text))
  end

  defp blocked_ctcp?(text), do: MessageText.ctcp_message?(text) and not MessageText.ctcp_action?(text)

  defp delayed?(_delay, _member, true), do: false
  defp delayed?(nil, _member, _privileged?), do: false
  defp delayed?(_delay, nil, _privileged?), do: false

  defp delayed?(delay, member, _privileged?) do
    {:ok, joined_at, _offset} = DateTime.from_iso8601(member.member["joined_at"])
    DateTime.diff(DateTime.utc_now(), joined_at) < String.to_integer(delay)
  end

  defp filter_status_target(memberships, target, channel) do
    if CaseMapping.normalize(target) == CaseMapping.normalize(channel) do
      memberships
    else
      prefix = String.first(target)
      Enum.filter(memberships, &Statusmsg.eligible?(&1, prefix))
    end
  end

  defp filter_op_moderated(memberships, status, modes, local_modes) do
    if (Map.has_key?(modes, "U") or :U in local_modes) and not privileged?(status) do
      Enum.filter(memberships, &(:o in &1.modes))
    else
      memberships
    end
  end

  defp privileged?(modes), do: "o" in modes or "v" in modes
end
