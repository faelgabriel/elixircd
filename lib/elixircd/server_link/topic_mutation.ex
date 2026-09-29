defmodule ElixIRCd.ServerLink.TopicMutation do
  @moduledoc "Applies a remote TOPIC request only at the selected channel authority."

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  defmodule Request do
    @moduledoc "Authenticated requester identity and proposed channel topic."

    @enforce_keys [:origin, :uid, :channel, :text]
    defstruct [:origin, :uid, :channel, :text]

    @type t :: %__MODULE__{
            origin: String.t(),
            uid: String.t(),
            channel: String.t(),
            text: String.t()
          }
  end

  defmodule Pending do
    @moduledoc "A local client request awaiting the selected authority's answer."

    @enforce_keys [:uid, :authority, :authority_epoch, :channel]
    defstruct [:uid, :authority, :authority_epoch, :channel]

    @type t :: %__MODULE__{
            uid: String.t(),
            authority: String.t(),
            authority_epoch: String.t(),
            channel: String.t()
          }
  end

  @type error ::
          :stale_authority | :unknown_sender | :not_on_channel | :topic_locked | :operator_required | :invalid_topic

  @doc "Checks committed replica and local policy, then changes the topic after one Mnesia commit."
  @spec apply(Request.t(), Replica.t(), ChannelView.t(), String.t()) :: {:ok, Channel.t()} | {:error, error()}
  def apply(%Request{} = request, %Replica{} = replica, %ChannelView{} = view, local_id) do
    Observability.transaction(fn -> apply_in_transaction(request, replica, view, local_id) end)
  end

  @doc "Constructs the typed authority request from a validated wire frame."
  @spec from_frame(map()) :: Request.t()
  def from_frame(frame) do
    %Request{
      origin: frame["origin"],
      uid: frame["from_uid"],
      channel: frame["channel"],
      text: frame["text"]
    }
  end

  @doc "Maps an authority decision to the closed result vocabulary on the wire."
  @spec result_code({:ok, Channel.t()} | {:error, error()}) :: String.t()
  def result_code({:ok, _channel}), do: "ok"
  def result_code({:error, reason}), do: Atom.to_string(reason)

  @doc "Delivers an authority rejection to the original real local connection."
  @spec reply(pid(), String.t(), String.t()) :: :ok
  def reply(_pid, _channel, "ok"), do: :ok

  def reply(pid, channel, code) do
    case Memento.transaction!(fn -> Users.get_by_pid(pid) end) do
      {:ok, user} -> Dispatcher.broadcast_without_history(error_message(user.nick, channel, code), :server, user)
      {:error, :user_not_found} -> :ok
    end
  end

  defp error_message(nick, channel, "not_on_channel") do
    %Message{command: :err_notonchannel, params: [nick, channel], trailing: "You're not on that channel"}
  end

  defp error_message(nick, channel, "operator_required") do
    %Message{command: :err_chanoprivsneeded, params: [nick, channel], trailing: "You're not a channel operator"}
  end

  defp error_message(nick, channel, "topic_locked") do
    %Message{
      command: :err_chanoprivsneeded,
      params: [nick, channel],
      trailing: "Topic changes are restricted by ChanServ"
    }
  end

  defp error_message(nick, _channel, "invalid_topic") do
    %Message{command: :err_inputtoolong, params: [nick], trailing: "Topic is invalid or too long"}
  end

  defp error_message(nick, channel, _code) do
    %Message{
      command: :err_unavailresource,
      params: [nick, channel],
      trailing: "Channel topic is temporarily unavailable on this server"
    }
  end

  defp apply_in_transaction(request, replica, view, local_id) do
    key = CaseMapping.normalize(request.channel)

    with :ok <- valid_text(request.text),
         {:ok, channel} <- local_authority(view, local_id, key),
         {:ok, sender} <- Replica.get_by_uid(replica, request.origin, request.uid),
         {:ok, member} <- remote_member(view, request),
         :ok <- permitted?(channel, member) do
      topic = topic(request.text, sender)
      updated = Channels.update(channel, %{topic: topic})
      sync_registered_channel_topic(channel.name, topic)
      announce_after_commit(updated, sender, request.text)
      {:ok, updated}
    else
      :error -> {:error, :unknown_sender}
      {:error, _reason} = error -> error
    end
  end

  defp local_authority(%ChannelView{origin: origin, channel: selected}, local_id, key) do
    with true <- origin == local_id,
         {:ok, channel} <- Channels.get_by_name(key),
         true <- same_identity?(channel, selected, local_id) do
      {:ok, channel}
    else
      _ -> {:error, :stale_authority}
    end
  end

  defp same_identity?(channel, selected, local_id) do
    creator =
      case Memento.Query.read(ChannelIdentity, channel.name_key) do
        %ChannelIdentity{creator: creator} -> creator
        nil -> local_id
      end

    case DateTime.from_iso8601(selected["created_at"]) do
      {:ok, created_at, _offset} ->
        creator == selected["creator"] and DateTime.compare(channel.created_at, created_at) == :eq

      _ ->
        false
    end
  end

  defp remote_member(view, request) do
    case Enum.find(view.remote_members, fn member ->
           member.origin == request.origin and member.member["uid"] == request.uid
         end) do
      nil -> {:error, :not_on_channel}
      member -> {:ok, member}
    end
  end

  defp permitted?(channel, member) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, %{settings: %{topiclock: true}}} ->
        {:error, :topic_locked}

      _ ->
        if :t in channel.modes and "o" not in member.effective_modes,
          do: {:error, :operator_required},
          else: :ok
    end
  end

  defp valid_text(text) do
    max_length = Application.fetch_env!(:elixircd, :channel)[:max_topic_length]

    if is_binary(text) and String.valid?(text) and String.length(text) <= max_length and
         not String.contains?(text, ["\r", "\n", <<0>>]),
       do: :ok,
       else: {:error, :invalid_topic}
  end

  defp topic("", _sender), do: nil

  defp topic(text, sender) do
    %Channel.Topic{
      text: text,
      setter: sender |> UserPayload.public_view() |> Protocol.user_mask(),
      set_at: DateTime.utc_now()
    }
  end

  @doc "Keeps local ChanServ topic persistence in sync with an authorized change."
  @spec sync_registered_channel_topic(String.t(), Channel.Topic.t() | nil) :: :ok
  def sync_registered_channel_topic(channel_name, topic) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, registered_channel} ->
        RegisteredChannels.update_topic(registered_channel, topic)
        :ok

      {:error, :registered_channel_not_found} ->
        :ok
    end
  end

  defp announce_after_commit(channel, sender, text) do
    recipients =
      channel.name
      |> UserChannels.get_by_channel_name()
      |> Enum.map(& &1.user_pid)
      |> Users.get_by_pids()

    prefix = sender |> UserPayload.public_view() |> Protocol.user_mask()
    message = %Message{command: "TOPIC", params: [channel.name], trailing: text, prefix: prefix}
    Observability.defer_effect(fn -> Dispatcher.broadcast_without_history(message, nil, recipients) end)
  end
end
