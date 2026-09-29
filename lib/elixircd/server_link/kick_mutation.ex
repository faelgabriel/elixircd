defmodule ElixIRCd.ServerLink.KickMutation do
  @moduledoc "Applies a routed KICK at the target user's home after checking committed channel authority."

  import ElixIRCd.Utils.MessageFilter, only: [filter_auditorium_users: 3]

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Tables.ChannelKickMarker
  alias ElixIRCd.Utils.Protocol

  defmodule Outbound do
    @moduledoc "A committed local KICK command addressed to a remote target UID."

    @enforce_keys [:sender_pid, :target_origin, :target_uid, :target_nick, :channel, :reason]
    defstruct [:sender_pid, :target_origin, :target_uid, :target_nick, :channel, :reason]

    @type t :: %__MODULE__{
            sender_pid: pid(),
            target_origin: String.t(),
            target_uid: String.t(),
            target_nick: String.t(),
            channel: String.t(),
            reason: String.t()
          }
  end

  defmodule Request do
    @moduledoc "Authenticated remote operator and target member for one KICK."

    @enforce_keys [:origin, :uid, :target_uid, :channel, :reason]
    defstruct [:origin, :uid, :target_uid, :channel, :reason]

    @type t :: %__MODULE__{
            origin: String.t(),
            uid: String.t(),
            target_uid: String.t(),
            channel: String.t(),
            reason: String.t()
          }
  end

  defmodule Pending do
    @moduledoc "A local KICK command awaiting its target home's decision."

    @enforce_keys [:uid, :authority, :authority_epoch, :target_uid, :target_nick, :channel]
    defstruct [:uid, :authority, :authority_epoch, :target_uid, :target_nick, :channel]

    @type t :: %__MODULE__{
            uid: String.t(),
            authority: String.t(),
            authority_epoch: String.t(),
            target_uid: String.t(),
            target_nick: String.t(),
            channel: String.t()
          }
  end

  @type error ::
          :stale_channel
          | :unknown_sender
          | :not_on_channel
          | :operator_required
          | :unknown_target
          | :target_not_on_channel
          | :registered_channel

  @doc "Constructs a typed request from a validated wire frame."
  @spec from_frame(map()) :: Request.t()
  def from_frame(frame) do
    %Request{
      origin: frame["origin"],
      uid: frame["from_uid"],
      target_uid: frame["to_uid"],
      channel: frame["channel"],
      reason: frame["reason"]
    }
  end

  @doc "Removes one local target in an observed transaction and announces KICK after commit."
  @spec apply_remote(Request.t(), Replica.t(), ChannelView.t(), String.t(), GenServer.server()) ::
          :ok | {:error, error()}
  def apply_remote(%Request{} = request, %Replica{} = replica, %ChannelView{} = view, local_id, projector) do
    case Projector.pid_for_uid(projector, request.target_uid) do
      {:ok, target_pid} ->
        Observability.transaction(fn -> apply_in_transaction(request, replica, view, local_id, target_pid) end)

      :error ->
        {:error, :unknown_target}
    end
  end

  @doc "Maps the target home's decision to a closed wire result code."
  @spec result_code(:ok | {:error, error()}) :: String.t()
  def result_code(:ok), do: "ok"
  def result_code({:error, reason}), do: Atom.to_string(reason)

  @doc "Reports a rejected remote KICK to its original local operator."
  @spec reply(pid(), String.t(), String.t(), String.t()) :: :ok
  def reply(_pid, _channel, _target, "ok"), do: :ok

  def reply(pid, channel, target, code) do
    case Memento.transaction!(fn -> Users.get_by_pid(pid) end) do
      {:ok, %{registered: true} = user} ->
        Dispatcher.broadcast_without_history(error_message(user.nick, channel, target, code), :server, user)

      _ ->
        :ok
    end
  end

  defp error_message(nick, channel, _target, "not_on_channel") do
    %Message{command: :err_notonchannel, params: [nick, channel], trailing: "You're not on that channel"}
  end

  defp error_message(nick, channel, _target, "operator_required") do
    %Message{command: :err_chanoprivsneeded, params: [nick, channel], trailing: "You're not channel operator"}
  end

  defp error_message(nick, _channel, target, "unknown_target") do
    %Message{command: :err_nosuchnick, params: [nick, target], trailing: "No such nick/channel"}
  end

  defp error_message(nick, channel, target, "target_not_on_channel") do
    %Message{command: :err_usernotinchannel, params: [nick, target, channel], trailing: "They aren't on that channel"}
  end

  defp error_message(nick, channel, _target, _code) do
    %Message{
      command: :err_unavailresource,
      params: [nick, channel],
      trailing: "Channel membership is temporarily unavailable on this network"
    }
  end

  defp apply_in_transaction(request, replica, view, local_id, target_pid) do
    with {:ok, channel} <- local_channel(view, local_id, request.channel),
         {:ok, sender} <- Replica.get_by_uid(replica, request.origin, request.uid),
         :ok <- operator_member(view, request),
         :ok <- unregistered_channel(channel),
         {:ok, target} <- local_target(target_pid),
         {:ok, membership} <- target_membership(target, channel) do
      recipients = local_recipients(channel, membership)
      mask = sender |> UserPayload.public_view() |> Protocol.user_mask()

      marker =
        %ChannelKickMarker{
          key: {channel.name_key, target.pid, DateTime.to_iso8601(membership.created_at)},
          actor_pid: nil,
          actor_origin: request.origin,
          actor_uid: request.uid,
          actor_mask: mask,
          reason: request.reason,
          created_at: DateTime.utc_now()
        }

      Memento.Query.write(marker)
      UserChannels.delete(membership)
      announce_after_commit(channel.name, target.nick, request.reason, mask, recipients)
      :ok
    else
      :error -> {:error, :unknown_sender}
      {:error, _reason} = error -> error
    end
  end

  defp local_channel(%ChannelView{channel: selected}, local_id, name) do
    with {:ok, channel} <- Channels.get_by_name(name),
         true <- same_identity?(channel, selected, local_id) do
      {:ok, channel}
    else
      _ -> {:error, :stale_channel}
    end
  end

  defp same_identity?(channel, selected, local_id) do
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
  end

  defp operator_member(view, request) do
    case Enum.find(view.remote_members, fn member ->
           member.origin == request.origin and member.member["uid"] == request.uid
         end) do
      nil -> {:error, :not_on_channel}
      member -> if "o" in member.effective_modes, do: :ok, else: {:error, :operator_required}
    end
  end

  defp unregistered_channel(channel) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, _registered} -> {:error, :registered_channel}
      {:error, :registered_channel_not_found} -> :ok
    end
  end

  defp local_target(pid) do
    case Users.get_by_pid(pid) do
      {:ok, %{registered: true} = user} -> {:ok, user}
      _ -> {:error, :unknown_target}
    end
  end

  defp target_membership(target, channel) do
    case UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name) do
      {:ok, membership} -> {:ok, membership}
      {:error, :user_channel_not_found} -> {:error, :target_not_on_channel}
    end
  end

  defp local_recipients(channel, membership) do
    channel.name
    |> UserChannels.get_by_channel_name()
    |> filter_auditorium_users(membership, channel.modes)
    |> Enum.map(& &1.user_pid)
    |> Users.get_by_pids()
  end

  defp announce_after_commit(channel, target, reason, mask, recipients) do
    message = %Message{command: "KICK", params: [channel, target], trailing: reason, prefix: mask}
    Observability.defer_effect(fn -> Dispatcher.broadcast_without_history(message, nil, recipients) end)
  end
end
