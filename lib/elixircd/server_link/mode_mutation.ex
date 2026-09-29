defmodule ElixIRCd.ServerLink.ModeMutation do
  @moduledoc "Applies routed channel metadata and list MODE changes at their selected authority."

  alias ElixIRCd.Commands.Mode.ChannelModes
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

  @metadata_modes [:C, :c, :d, :i, :j, :k, :l, :m, :M, :N, :n, :p, :R, :s, :t, :T, :U, :u, :z]
  @list_modes [:b, :e, :I]

  defmodule Outbound do
    @moduledoc "One committed local MODE command addressed to a remote authority."

    @enforce_keys [:sender_pid, :authority, :channel, :mode_string, :values]
    defstruct [:sender_pid, :authority, :channel, :mode_string, :values]

    @type t :: %__MODULE__{
            sender_pid: pid(),
            authority: String.t(),
            channel: String.t(),
            mode_string: String.t(),
            values: [String.t()]
          }
  end

  defmodule Request do
    @moduledoc "Authenticated actor and proposed metadata mode operation."

    @enforce_keys [:origin, :uid, :channel, :mode_string, :values]
    defstruct [:origin, :uid, :channel, :mode_string, :values]

    @type t :: %__MODULE__{
            origin: String.t(),
            uid: String.t(),
            channel: String.t(),
            mode_string: String.t(),
            values: [String.t()]
          }
  end

  defmodule Pending do
    @moduledoc "A local MODE command awaiting its selected authority."

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
          :stale_authority
          | :unknown_sender
          | :not_on_channel
          | :operator_required
          | :invalid_mode
          | :unsupported_mode
          | :registered_channel

  @doc "Applies a validated metadata or list MODE command in one observed Mnesia transaction."
  @spec apply(Request.t(), Replica.t(), ChannelView.t(), String.t()) ::
          {:ok, Channel.t(), [ChannelModes.mode_change()]} | {:error, error()}
  def apply(%Request{} = request, %Replica{} = replica, %ChannelView{} = view, local_id) do
    Observability.transaction(fn -> apply_in_transaction(request, replica, view, local_id) end)
  end

  @doc "Constructs a typed request from a validated wire frame."
  @spec from_frame(map()) :: Request.t()
  def from_frame(frame) do
    %Request{
      origin: frame["origin"],
      uid: frame["from_uid"],
      channel: frame["channel"],
      mode_string: frame["modes"],
      values: frame["values"]
    }
  end

  @doc "Maps the authority decision to one bounded wire result code."
  @spec result_code({:ok, Channel.t(), [ChannelModes.mode_change()]} | {:error, error()}) :: String.t()
  def result_code({:ok, _channel, _changes}), do: "ok"
  def result_code({:error, reason}), do: Atom.to_string(reason)

  @doc "Sends a rejected MODE command to its original local connection."
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

  defp error_message(nick, channel, code) when code in ["invalid_mode", "unsupported_mode"] do
    %Message{command: :err_unknownmode, params: [nick, channel], trailing: "Unsupported network channel mode change"}
  end

  defp error_message(nick, channel, _code) do
    %Message{
      command: :err_unavailresource,
      params: [nick, channel],
      trailing: "Channel modes are temporarily unavailable on this server"
    }
  end

  defp apply_in_transaction(request, replica, view, local_id) do
    key = CaseMapping.normalize(request.channel)

    with {:ok, changes} <- metadata_changes(request),
         {:ok, channel} <- local_authority(view, local_id, key),
         {:ok, sender} <- Replica.get_by_uid(replica, request.origin, request.uid),
         {:ok, member} <- remote_member(view, request),
         :ok <- operator?(member),
         :ok <- unregistered_channel?(channel),
         {:ok, actor} <- remote_actor(sender, changes) do
      {updated, applied} = ChannelModes.apply_mode_changes(actor, channel, changes)
      announce_after_commit(updated, sender, applied)
      {:ok, updated, applied}
    else
      :error -> {:error, :unknown_sender}
      {:error, _reason} = error -> error
    end
  end

  defp metadata_changes(request) do
    max_modes = Application.fetch_env!(:elixircd, :channel)[:max_modes_per_command]

    {parsed, invalid} = ChannelModes.parse_mode_changes(request.mode_string, request.values)
    {changes, listing, missing} = ChannelModes.filter_mode_changes(parsed)

    with :ok <- parsed_modes_valid?(parsed, invalid, max_modes),
         :ok <- arguments_consumed?(parsed, request.values),
         :ok <- parameters_valid?(changes, listing, missing),
         :ok <- supported_changes?(changes) do
      {:ok, changes}
    end
  end

  defp parsed_modes_valid?(parsed, invalid, max_modes) do
    if invalid == [] and length(parsed) in 1..max_modes, do: :ok, else: {:error, :invalid_mode}
  end

  defp arguments_consumed?(parsed, values) do
    consumed = Enum.count(parsed, fn {_action, mode} -> is_tuple(mode) end)
    if consumed == length(values), do: :ok, else: {:error, :invalid_mode}
  end

  defp parameters_valid?(changes, listing, missing) do
    if changes != [] and listing == [] and missing == [] and ChannelModes.valid_mode_parameters?(changes),
      do: :ok,
      else: {:error, :invalid_mode}
  end

  defp supported_changes?(changes) do
    if Enum.all?(changes, &supported_change?/1), do: :ok, else: {:error, :unsupported_mode}
  end

  defp supported_change?({_action, {mode, value}}) when mode in @list_modes,
    do: valid_list_mask?(value)

  defp supported_change?({_action, {mode, _value}}), do: mode in @metadata_modes
  defp supported_change?({_action, mode}), do: mode in @metadata_modes

  defp valid_list_mask?(mask) when is_binary(mask) do
    if mask != "" and String.valid?(mask) do
      normalized = Protocol.normalize_mask(mask)
      byte_size(normalized) <= 255 and not Regex.match?(~r/[\x00-\x20\x7f]/u, normalized)
    else
      false
    end
  end

  defp valid_list_mask?(_mask), do: false

  defp remote_actor(sender, changes) do
    mask = sender |> UserPayload.public_view() |> Protocol.user_mask()
    adds_list? = Enum.any?(changes, &match?({:add, {mode, _value}} when mode in @list_modes, &1))

    if adds_list? and byte_size(mask) > 255,
      do: {:error, :invalid_mode},
      else: {:ok, %ChannelModes.RemoteActor{mask: mask}}
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

  defp operator?(member) do
    if "o" in member.effective_modes, do: :ok, else: {:error, :operator_required}
  end

  defp unregistered_channel?(channel) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, _registered} -> {:error, :registered_channel}
      {:error, :registered_channel_not_found} -> :ok
    end
  end

  defp announce_after_commit(_channel, _sender, []), do: :ok

  defp announce_after_commit(channel, sender, changes) do
    recipients =
      channel.name
      |> UserChannels.get_by_channel_name()
      |> Enum.map(& &1.user_pid)
      |> Users.get_by_pids()

    prefix = sender |> UserPayload.public_view() |> Protocol.user_mask()
    display = ChannelModes.display_mode_changes(changes)
    message = %Message{command: "MODE", params: [channel.name, display], prefix: prefix}
    Observability.defer_effect(fn -> Dispatcher.broadcast_without_history(message, nil, recipients) end)
  end
end
