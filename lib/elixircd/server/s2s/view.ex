defmodule ElixIRCd.Server.S2S.View do
  @moduledoc """
  Read-only adapters from the native S2S projection to C2S-shaped values.

  The adapters never write Mnesia and never invent a local PID. They are used
  by local queries when a global user or channel is present only in the
  network projection.
  """

  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.ServiceEndpoint
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.Channel.Topic
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping

  @chanserv_uid "service:ChanServ"

  @doc "Returns the current network projection when native S2S is running."
  @spec runtime(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def runtime(server) do
    {:ok, Manager.runtime_view(server)}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Builds a read-only User projection for one reachable UID."
  @spec user(map(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def user(runtime, uid), do: ServiceEndpoint.caller_user(runtime, uid)

  @doc "Resolves a nickname against the effective network projection."
  @spec user_by_nick(map(), String.t()) ::
          {:ok, String.t(), User.t()} | {:error, :user_not_found | :user_unavailable}
  def user_by_nick(%{users: users} = runtime, nickname)
      when is_map(users) and is_binary(nickname) do
    key = CaseMapping.normalize(nickname)

    case Enum.find(users, fn {_uid, projection} ->
           CaseMapping.normalize(projection["effective_nick"] || projection["requested_nick"] || "") == key
         end) do
      {uid, _projection} ->
        {:ok, projected} = user(runtime, uid)
        {:ok, uid, projected}

      nil ->
        {:error, :user_not_found}
    end
  end

  def user_by_nick(_runtime, _nickname), do: {:error, :user_unavailable}

  @doc "Builds the transient logical ChanServ endpoint when global services are ready."
  @spec chanserv_user(map()) :: {:ok, User.t()} | {:error, :service_unavailable}
  def chanserv_user(runtime) when is_map(runtime) do
    with true <- services_ready?(runtime),
         authority when is_binary(authority) <- runtime[:services_authority],
         authority_node when is_map(authority_node) <- runtime.nodes[authority],
         boot when is_binary(boot) <- authority_node["boot"] do
      hostname = Application.fetch_env!(:elixircd, :server)[:hostname]
      now = :erlang.system_time(:second)

      service =
        User.new(%{
          uid: @chanserv_uid,
          pid: nil,
          connection_generation: @chanserv_uid,
          home_sid: authority,
          home_boot: boot,
          effective_nick: "ChanServ",
          nick: "ChanServ",
          transport: :tls,
          ip_address: {0, 0, 0, 0},
          port_connected: 0,
          hostname: hostname,
          cloaked_hostname: hostname,
          ident: "service",
          realname: "ChanServ",
          registered: true,
          modes: [],
          capabilities: [],
          identified_as: nil,
          sasl_authenticated: false,
          last_activity: now,
          registered_at: DateTime.from_unix!(now),
          created_at: DateTime.from_unix!(now)
        })
        |> Map.put(:cloaked_hostname, hostname)

      {:ok, service}
    else
      _ -> {:error, :service_unavailable}
    end
  end

  def chanserv_user(_runtime), do: {:error, :service_unavailable}

  @doc "Resolves the logical ChanServ endpoint for exact query commands only."
  @spec chanserv_user_by_nick(map(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def chanserv_user_by_nick(runtime, nickname) when is_binary(nickname) do
    if CaseMapping.normalize(nickname) == CaseMapping.normalize("ChanServ"),
      do: chanserv_user(runtime),
      else: {:error, :user_not_found}
  end

  def chanserv_user_by_nick(_runtime, _nickname), do: {:error, :user_not_found}

  @doc "Returns whether the configured service authority is reachable with a ready policy."
  @spec services_ready?(map()) :: boolean()
  def services_ready?(runtime) when is_map(runtime) do
    authority = runtime[:services_authority]
    sid = runtime[:sid]
    reachable = runtime[:reachable_sids] || MapSet.new()

    is_binary(authority) and
      Policy.grant_ready?(runtime[:policy]) and
      (authority == sid or MapSet.member?(reachable, authority))
  rescue
    _ -> false
  end

  def services_ready?(_runtime), do: false

  @doc "Returns a transient ChanServ membership for a guarded current channel."
  @spec chanserv_membership(map(), String.t()) ::
          {:ok, User.t(), UserChannel.t()} | {:error, term()}
  def chanserv_membership(runtime, channel_name) when is_binary(channel_name) do
    if String.starts_with?(channel_name, "&") do
      {:error, :local_channel}
    else
      with {:ok, service} <- chanserv_user(runtime),
           {:ok, channel, runtime_channel} <- channel(runtime, channel_name),
           true <- guarded_channel?(runtime, channel.name_key) do
        born_ms = max(runtime_channel.ref["born_ms"] || 1, 1)

        membership =
          UserChannel.new(%{
            uid: service.uid,
            user_pid: nil,
            channel_name_key: channel.name_key,
            join_id: nil,
            joined_ms: born_ms,
            modes: [],
            created_at: DateTime.from_unix!(born_ms, :millisecond)
          })

        {:ok, service, membership}
      else
        false -> {:error, :guard_disabled}
        error -> error
      end
    end
  end

  def chanserv_membership(_runtime, _channel_name), do: {:error, :channel_not_found}

  @doc "Returns real projected members plus a derived ChanServ membership when GUARD applies."
  @spec channel_members_with_services(map(), map()) :: [{String.t(), User.t(), UserChannel.t()}]
  def channel_members_with_services(runtime, channel) do
    members = channel_members(runtime, channel)

    case chanserv_membership(runtime, channel.ref["name"]) do
      {:ok, service, membership} -> members ++ [{service.uid, service, membership}]
      _ -> members
    end
  end

  @doc "Returns guarded channels visible to a viewer, without materializing service rows."
  @spec guarded_service_channels(map(), String.t() | nil) :: [Channel.t()]
  def guarded_service_channels(runtime, viewer_uid \\ nil) do
    if services_ready?(runtime) do
      runtime.channels
      |> Map.values()
      |> Enum.flat_map(&projected_channel(runtime, &1))
      |> Enum.filter(fn channel ->
        not String.starts_with?(channel.name, "&") and
          guarded_channel?(runtime, channel.name_key) and
          service_channel_visible?(runtime, channel, viewer_uid)
      end)
      |> Enum.sort_by(&CaseMapping.normalize(&1.name))
    else
      []
    end
  end

  @doc "Builds a read-only Channel projection for one current incarnation."
  @spec channel(map(), String.t()) :: {:ok, Channel.t(), map()} | {:error, term()}
  def channel(runtime, name) when is_binary(name) do
    key = CaseMapping.normalize(name)

    case runtime.channels[key] do
      %{ref: _ref} = value -> {:ok, channel_struct(value), value}
      _ -> {:error, :channel_not_found}
    end
  end

  @doc "Returns projected users and membership-shaped values for one channel."
  @spec channel_members(map(), map()) :: [{String.t(), User.t(), UserChannel.t()}]
  def channel_members(runtime, %{ref: ref} = channel) do
    name_key = CaseMapping.normalize(ref["name"])

    runtime.memberships
    |> Enum.flat_map(fn {uid, membership} ->
      project_channel_member(runtime, uid, membership, name_key, channel)
    end)
  end

  def channel_members(_runtime, _channel), do: []

  @doc "Returns one current projected membership for a UID and channel."
  @spec membership(map(), String.t(), String.t()) :: {:ok, UserChannel.t()} | {:error, term()}
  def membership(runtime, uid, channel_name) do
    key = CaseMapping.normalize(channel_name)

    with %{entries: entries} = _membership <- runtime.memberships[uid],
         entry when is_map(entry) <- Enum.find(entries, &(CaseMapping.normalize(&1["channel"]) == key)),
         {:ok, _channel_struct, channel} <- channel(runtime, channel_name) do
      {:ok, membership_record(runtime, uid, entry, channel)}
    else
      _ -> {:error, :membership_not_found}
    end
  end

  defp channel_struct(channel) do
    ref = channel.ref

    Channel.new(%{
      name: ref["name"],
      born_ms: ref["born_ms"],
      cid: ref["cid"],
      modes: channel_modes(channel),
      topic: channel_topic(channel),
      created_at: DateTime.from_unix!(max(ref["born_ms"], 1), :millisecond)
    })
    |> Map.put(:name_key, CaseMapping.normalize(ref["name"]))
  end

  defp membership_record(_runtime, uid, entry, channel) do
    modes =
      ["o", "v"]
      |> Enum.filter(fn mode ->
        get_in(channel, [:statuses, {uid, entry["join_id"], mode}, :value, :enabled]) == true
      end)
      |> Enum.map(fn
        "o" -> :o
        "v" -> :v
      end)

    UserChannel.new(%{
      uid: uid,
      user_pid: nil,
      channel_name_key: CaseMapping.normalize(entry["channel"]),
      join_id: entry["join_id"],
      joined_ms: entry["joined_ms"],
      modes: modes,
      created_at: DateTime.from_unix!(max(entry["joined_ms"], 1), :millisecond)
    })
  end

  defp channel_modes(channel) do
    fields =
      channel.registers
      |> Enum.flat_map(fn
        {"mode:" <> character, %{value: value}} ->
          case ModeRegistry.decode(:channel, character) do
            {:ok, mode} -> mode_value(mode, value)
            :error -> []
          end

        _ ->
          []
      end)

    Enum.uniq(fields)
  end

  defp mode_value(mode, value) do
    case Enum.find(ChannelModes.mode_types(), fn {candidate, _type} -> candidate == mode end) do
      {_mode, type} when type in [:d, :prefix] -> if value == true, do: [mode], else: []
      {_mode, _type} when is_binary(value) -> [{mode, value}]
      {_mode, _type} when is_integer(value) -> [{mode, Integer.to_string(value)}]
      _ -> []
    end
  end

  defp channel_topic(channel) do
    case channel.registers["topic"] do
      %{value: %{"text" => text, "setter" => setter, "set_ms" => set_ms}}
      when is_binary(text) and is_binary(setter) and is_integer(set_ms) ->
        %Topic{text: text, setter: setter, set_at: DateTime.from_unix!(max(set_ms, 0), :millisecond)}

      _ ->
        nil
    end
  end

  defp guarded_channel?(runtime, channel_key) do
    match?({:ok, %{"settings" => %{"guard" => true}}}, Policy.get(runtime.policy, "channel", channel_key))
  end

  defp service_channel_visible?(_runtime, _channel, nil), do: true

  defp service_channel_visible?(runtime, channel, viewer_uid) when is_binary(viewer_uid) do
    match?({:ok, _}, membership(runtime, viewer_uid, channel.name)) or
      (:s not in channel.modes and :p not in channel.modes)
  end

  defp service_channel_visible?(_runtime, _channel, _viewer_uid), do: true

  defp projected_channel(runtime, runtime_channel) do
    case channel(runtime, runtime_channel.ref["name"]) do
      {:ok, channel, _} -> [channel]
      _ -> []
    end
  end

  defp project_channel_member(runtime, uid, membership, name_key, channel) do
    case Enum.find(membership.entries, &(CaseMapping.normalize(&1["channel"]) == name_key)) do
      nil -> []
      entry -> project_channel_entry(runtime, uid, entry, channel)
    end
  end

  defp project_channel_entry(runtime, uid, entry, channel) do
    {:ok, projected} = user(runtime, uid)
    [{uid, projected, membership_record(runtime, uid, entry, channel)}]
  end
end
