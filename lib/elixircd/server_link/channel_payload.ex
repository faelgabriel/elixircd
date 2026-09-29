defmodule ElixIRCd.ServerLink.ChannelPayload do
  @moduledoc "PID-free, bounded channel metadata and per-origin channel entries."

  alias ElixIRCd.Config.Types
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.UserChannel

  @channel_modes ModeRegistry.modes(:channel) -- [:b, :e, :I, :o, :v]
  @channel_mode_names Enum.map(@channel_modes, &ModeRegistry.encode!(:channel, &1))
  @parameter_modes ~w(d j k l)
  @membership_mode_names Enum.map(ModeRegistry.modes(:membership), &ModeRegistry.encode!(:membership, &1))
  @list_kinds ~w(b e I)

  @doc "Serializes channel metadata without local table keys or Erlang terms."
  @spec from_local(Channel.t(), String.t()) :: map()
  def from_local(channel, creator \\ Application.fetch_env!(:elixircd, :server)[:hostname]) do
    %{
      "name" => channel.name,
      "creator" => creator,
      "created_at" => DateTime.to_iso8601(channel.created_at),
      "topic" => topic_from_local(channel.topic),
      "modes" => Enum.map(channel.modes, &mode_from_local/1)
    }
  end

  @doc "Converts validated network metadata into local channel attributes."
  @spec to_local(map()) :: {:ok, map()} | {:error, :invalid_channel}
  def to_local(payload) do
    with :ok <- validate_channel(payload),
         {:ok, created_at, _offset} <- DateTime.from_iso8601(payload["created_at"]),
         {:ok, modes} <- decode_modes(payload["modes"]) do
      topic =
        case payload["topic"] do
          nil ->
            nil

          wire ->
            {:ok, set_at, _offset} = DateTime.from_iso8601(wire["set_at"])
            %Channel.Topic{text: wire["text"], setter: wire["setter"], set_at: set_at}
        end

      {:ok,
       %{
         name: payload["name"],
         creator: payload["creator"],
         created_at: created_at,
         topic: topic,
         modes: modes
       }}
    else
      _ -> {:error, :invalid_channel}
    end
  end

  defp decode_modes(wire_modes) do
    Enum.reduce_while(wire_modes, {:ok, []}, fn wire, {:ok, modes} ->
      case decode_mode(wire) do
        {:ok, mode} -> {:cont, {:ok, [mode | modes]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, modes} -> {:ok, Enum.reverse(modes)}
      error -> error
    end
  end

  defp decode_mode(wire) do
    case ModeRegistry.decode(:channel, wire["name"]) do
      {:ok, mode} -> {:ok, if(wire["parameter"], do: {mode, wire["parameter"]}, else: mode)}
      :error -> {:error, :invalid_channel}
    end
  end

  @doc "Serializes a local membership using the owning user's network UID."
  @spec member_from_local(UserChannel.t(), String.t(), String.t()) :: map()
  def member_from_local(membership, channel_name, uid) do
    %{
      "channel" => channel_name,
      "uid" => uid,
      "modes" => Enum.map(membership.modes, &ModeRegistry.encode!(:membership, &1)),
      "joined_at" => DateTime.to_iso8601(membership.created_at)
    }
  end

  @doc "Serializes a ban, exception or invite exception list entry."
  @spec list_from_local(struct(), String.t(), String.t()) :: map()
  def list_from_local(entry, channel_name, kind) do
    %{
      "channel" => channel_name,
      "kind" => kind,
      "mask" => entry.mask,
      "setter" => entry.setter,
      "set_at" => DateTime.to_iso8601(entry.created_at)
    }
  end

  @doc "Serializes an invite addressed to a local user UID."
  @spec invite_from_local(ChannelInvite.t(), String.t(), String.t()) :: map()
  def invite_from_local(invite, channel_name, uid) do
    %{
      "channel" => channel_name,
      "uid" => uid,
      "setter" => invite.setter,
      "bypass_ban" => invite.bypass_ban,
      "created_at" => DateTime.to_iso8601(invite.created_at)
    }
  end

  @doc "Validates a bounded channel metadata record with a closed mode vocabulary."
  @spec validate_channel(term()) :: :ok | {:error, :invalid_channel}
  def validate_channel(payload) when is_map(payload) do
    valid =
      exact_keys?(payload, ~w(name creator created_at topic modes)) and
        channel_name?(payload["name"]) and timestamp?(payload["created_at"]) and
        creator?(payload["creator"]) and
        topic?(payload["topic"]) and modes?(payload["modes"])

    if valid, do: :ok, else: {:error, :invalid_channel}
  end

  def validate_channel(_payload), do: {:error, :invalid_channel}

  @doc "Validates a local-user membership entry."
  @spec validate_member(term()) :: :ok | {:error, :invalid_member}
  def validate_member(payload) when is_map(payload) do
    modes = payload["modes"]

    valid =
      exact_keys?(payload, ~w(channel uid modes joined_at)) and
        channel_name?(payload["channel"]) and UserPayload.uid?(payload["uid"]) and
        is_list(modes) and Enum.all?(modes, &(&1 in @membership_mode_names)) and
        modes == Enum.uniq(modes) and timestamp?(payload["joined_at"])

    if valid, do: :ok, else: {:error, :invalid_member}
  end

  def validate_member(_payload), do: {:error, :invalid_member}

  @doc "Validates a ban, exception or invite exception entry."
  @spec validate_list(term()) :: :ok | {:error, :invalid_list}
  def validate_list(payload) when is_map(payload) do
    valid =
      exact_keys?(payload, ~w(channel kind mask setter set_at)) and
        channel_name?(payload["channel"]) and payload["kind"] in @list_kinds and
        safe_text?(payload["mask"], 255) and safe_text?(payload["setter"], 255) and
        timestamp?(payload["set_at"])

    if valid, do: :ok, else: {:error, :invalid_list}
  end

  def validate_list(_payload), do: {:error, :invalid_list}

  @doc "Validates an invite addressed to a user owned by the entry origin."
  @spec validate_invite(term()) :: :ok | {:error, :invalid_invite}
  def validate_invite(payload) when is_map(payload) do
    valid =
      exact_keys?(payload, ~w(channel uid setter bypass_ban created_at)) and
        channel_name?(payload["channel"]) and UserPayload.uid?(payload["uid"]) and
        safe_text?(payload["setter"], 255) and is_boolean(payload["bypass_ban"]) and
        timestamp?(payload["created_at"])

    if valid, do: :ok, else: {:error, :invalid_invite}
  end

  def validate_invite(_payload), do: {:error, :invalid_invite}

  defp topic_from_local(nil), do: nil

  defp topic_from_local(topic) do
    %{"text" => topic.text, "setter" => topic.setter, "set_at" => DateTime.to_iso8601(topic.set_at)}
  end

  defp mode_from_local({mode, parameter}),
    do: %{"name" => ModeRegistry.encode!(:channel, mode), "parameter" => parameter}

  defp mode_from_local(mode), do: %{"name" => ModeRegistry.encode!(:channel, mode), "parameter" => nil}

  defp topic?(nil), do: true

  defp topic?(topic) when is_map(topic) do
    exact_keys?(topic, ~w(text setter set_at)) and safe_text?(topic["text"], 1024, true) and
      safe_text?(topic["setter"], 255) and timestamp?(topic["set_at"])
  end

  defp topic?(_topic), do: false

  defp modes?(modes) when is_list(modes) do
    length(modes) <= length(@channel_modes) and
      Enum.all?(modes, &mode?/1) and
      Enum.map(modes, & &1["name"]) |> Enum.uniq() |> length() == length(modes)
  end

  defp modes?(_modes), do: false

  defp mode?(mode) when is_map(mode) do
    name = mode["name"]
    parameter = mode["parameter"]

    exact_keys?(mode, ~w(name parameter)) and name in @channel_mode_names and
      if(name in @parameter_modes, do: safe_text?(parameter, 255), else: is_nil(parameter))
  end

  defp mode?(_mode), do: false

  defp channel_name?(name),
    do: Types.valid?(:channel_pattern, name) and String.starts_with?(name, "#") and byte_size(name) <= 255

  defp creator?(creator),
    do: Types.valid?(:server_hostname, creator) and creator == String.downcase(creator)

  defp safe_text?(value, max, allow_empty \\ false) do
    is_binary(value) and byte_size(value) <= max and String.valid?(value) and
      (allow_empty or value != "") and not Regex.match?(~r/[\x00-\x1f\x7f]/, value)
  end

  defp timestamp?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp timestamp?(_value), do: false

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
end
