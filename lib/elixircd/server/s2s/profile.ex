defmodule ElixIRCd.Server.S2S.Profile do
  @moduledoc """
  ENP/1 semantic profile and configured-tree validation.

  The hash is computed from a fixed-position array. Secrets, local addresses,
  certificate pins and queue preferences never enter that array.
  """

  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Server.S2S.Identity

  @protocol "elixircd-native"
  @version 1
  @policy_schema_revision 1

  @doc "Builds the fixed-position shared profile array from an application config."
  @spec profile_array(keyword() | map()) :: list()
  def profile_array(config) do
    s2s = section(config, :s2s)
    settings = section(config, :settings)
    user = section(config, :user)
    channel = section(config, :channel)

    [
      @protocol,
      @version,
      value(s2s, :semantic_revision, 1),
      value(s2s, :network_id, ""),
      roster_rows(value(s2s, :roster, [])),
      value(s2s, :services_authority, nil),
      Atom.to_string(value(settings, :case_mapping, :rfc1459)),
      value(settings, :utf8_only, true),
      [
        value(user, :max_nick_length, 30),
        value(user, :max_ident_length, 10),
        value(user, :max_realname_length, 50),
        value(user, :max_away_message_length, 200)
      ],
      [
        prefix(channel, "#"),
        prefix(channel, "&"),
        value(channel, :max_channel_name_length, 64),
        join_limit(channel, "#", 20),
        value(channel, :max_topic_length, 300),
        value(channel, :max_kick_message_length, 255),
        value(channel, :max_modes_per_command, 20),
        list_limit(channel, :b, 100),
        list_limit(channel, :e, 100),
        list_limit(channel, :I, 100)
      ],
      mode_rows(),
      @policy_schema_revision
    ]
  end

  @doc "Returns compact UTF-8 JSON for the shared profile."
  @spec encoded_profile(keyword() | map()) :: binary()
  def encoded_profile(config), do: IO.iodata_to_binary(:json.encode(profile_array(config)))

  @doc "Returns the lowercase hexadecimal SHA-256 profile fingerprint."
  @spec hash(keyword() | map()) :: String.t()
  def hash(config), do: Identity.sha256_hex(encoded_profile(config))

  @doc "Builds a hello frame for this daemon."
  @spec hello(keyword() | map(), String.t(), String.t(), non_neg_integer()) :: map()
  def hello(config, boot, nonce, time_ms \\ Identity.now_ms()) do
    s2s = section(config, :s2s)
    server = section(config, :server)

    %{
      "t" => "hello",
      "protocol" => @protocol,
      "version" => @version,
      "network_id" => value(s2s, :network_id, ""),
      "profile_hash" => hash(config),
      "sid" => value(s2s, :server_id, ""),
      "boot" => boot,
      "name" => value(s2s, :server_name, value(server, :hostname, "")),
      "nonce" => nonce,
      "time_ms" => time_ms
    }
  end

  @doc "Validates the static roster and returns normalized rows."
  @spec validate_roster(term()) :: {:ok, [map()]} | {:error, [atom() | tuple()]}
  def validate_roster(roster) when is_list(roster) do
    rows = Enum.map(roster, &normalize_roster_row/1)

    errors =
      []
      |> add_if(Enum.all?(rows, &valid_roster_row?/1), :invalid_roster_row)
      |> add_if(length(rows) == length(Enum.uniq_by(rows, & &1.sid)), :duplicate_sid)
      |> add_if(length(rows) == length(Enum.uniq_by(rows, & &1.name)), :duplicate_name)
      |> add_if(length(rows) <= 256, :too_many_nodes)
      |> add_if(Enum.count(rows, &is_nil(&1.parent)) == 1, :root_count)
      |> Kernel.++(parent_errors(rows))
      |> Kernel.++(cycle_errors(rows))

    if errors == [], do: {:ok, Enum.sort_by(rows, & &1.sid)}, else: {:error, Enum.uniq(errors)}
  rescue
    _ -> {:error, [:invalid_roster]}
  end

  def validate_roster(_roster), do: {:error, [:invalid_roster]}

  @doc "Validates a full profile before a listener or connector is activated."
  @spec validate(keyword() | map()) :: :ok | {:error, [term()]}
  def validate(config) do
    s2s = section(config, :s2s)
    enabled = value(s2s, :enabled, false)

    cond do
      enabled == false ->
        :ok

      enabled != true ->
        {:error, [:invalid_enabled]}

      true ->
        with true <- Identity.valid_network_id?(value(s2s, :network_id, "")),
             true <- Identity.valid_sid?(value(s2s, :server_id, "")),
             {:ok, roster} <- validate_roster(value(s2s, :roster, [])),
             {:ok, local} <- fetch_server(roster, value(s2s, :server_id, "")),
             :ok <- local_connection_shape(local, value(s2s, :parent_connection, nil)),
             :ok <- validate_neighbor_credentials(roster, local, s2s),
             true <- authority_in_roster?(roster, value(s2s, :services_authority, nil)) do
          :ok
        else
          {:error, _} = error -> error
          _ -> {:error, [:invalid_profile]}
        end
    end
  end

  @doc "Returns the deterministic ENP mode descriptors used in the profile."
  @spec mode_rows() :: [[String.t()]]
  def mode_rows do
    channel_rows =
      ChannelModes.mode_types()
      |> Enum.map(fn {mode, argument_class} -> ["channel", Atom.to_string(mode), Atom.to_string(argument_class), 1] end)

    membership_rows = Enum.map(ModeRegistry.modes(:membership), &["membership", Atom.to_string(&1), "prefix", 1])
    user_rows = Enum.map(ModeRegistry.modes(:user), &["user", Atom.to_string(&1), "d", 1])

    Enum.sort_by(channel_rows ++ membership_rows ++ user_rows, fn [context, letter | _] -> {context, letter} end)
  end

  defp normalize_roster_row(row) when is_map(row) do
    %{
      sid: row[:sid] || row["sid"],
      name: row[:name] || row["name"],
      parent: row[:parent] || row["parent"]
    }
  end

  defp normalize_roster_row(row) when is_list(row) do
    %{
      sid: value(row, :sid, nil),
      name: value(row, :name, nil),
      parent: value(row, :parent, nil)
    }
  end

  defp normalize_roster_row(_row), do: %{sid: nil, name: nil, parent: nil}

  defp valid_roster_row?(%{sid: sid, name: name, parent: parent}) do
    Identity.valid_sid?(sid) and
      is_binary(name) and byte_size(name) in 1..255 and String.valid?(name) and
      (is_nil(parent) or Identity.valid_sid?(parent))
  end

  defp valid_roster_row?(_row), do: false

  defp fetch_server(rows, sid) do
    case Enum.find(rows, &(&1.sid == sid)) do
      nil -> {:error, [:server_id_missing_from_roster]}
      row -> {:ok, row}
    end
  end

  defp local_connection_shape(%{parent: nil}, nil), do: :ok
  defp local_connection_shape(%{parent: parent}, connection) when is_binary(parent) and is_list(connection), do: :ok
  defp local_connection_shape(_row, _connection), do: {:error, [:parent_connection_mismatch]}

  defp validate_neighbor_credentials(roster, local, s2s) do
    children = value(s2s, :children, %{})

    neighbor_sids =
      [local.parent | Enum.map(Enum.filter(roster, &(&1.parent == local.sid)), & &1.sid)] |> Enum.reject(&is_nil/1)

    configured_sids = children |> Map.keys() |> Enum.map(&to_string/1)

    errors =
      []
      |> add_if(Enum.all?(configured_sids, &(&1 in neighbor_sids)), :unknown_child_configuration)
      |> add_if(Enum.all?(neighbor_sids, &neighbor_configured?(&1, local, s2s)), :missing_neighbor_credentials)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp neighbor_configured?(sid, %{parent: sid}, s2s), do: valid_parent_connection?(value(s2s, :parent_connection, nil))

  defp neighbor_configured?(sid, %{sid: _local_sid}, s2s) do
    case Map.get(value(s2s, :children, %{}), sid) || Map.get(value(s2s, :children, %{}), to_string(sid)) do
      child when is_list(child) -> is_list(value(child, :pins, [])) and value(child, :pins, []) != []
      child when is_map(child) -> is_list(value(child, :pins, [])) and value(child, :pins, []) != []
      _ -> false
    end
  end

  defp neighbor_configured?(_sid, _local, _s2s), do: false

  defp valid_parent_connection?(connection) when is_list(connection) or is_map(connection) do
    pins = value(connection, :pins, [])
    is_list(pins) and pins != []
  end

  defp valid_parent_connection?(_connection), do: false

  defp authority_in_roster?(_rows, nil), do: true
  defp authority_in_roster?(rows, authority), do: Enum.any?(rows, &(&1.sid == authority))

  defp parent_errors(rows) do
    sids = MapSet.new(Enum.map(rows, & &1.sid))

    Enum.flat_map(rows, fn
      %{parent: nil} ->
        []

      %{parent: parent} when is_binary(parent) ->
        if(MapSet.member?(sids, parent), do: [], else: [{:missing_parent, parent}])

      _ ->
        [:invalid_parent]
    end)
  end

  defp cycle_errors(rows) do
    by_sid = Map.new(rows, &{&1.sid, &1.parent})

    Enum.flat_map(rows, fn row -> if cycle?(row.sid, by_sid, MapSet.new()), do: [{:cycle, row.sid}], else: [] end)
  end

  defp cycle?(nil, _parents, _seen), do: false

  defp cycle?(sid, parents, seen) do
    cond do
      MapSet.member?(seen, sid) -> true
      not Map.has_key?(parents, sid) -> false
      true -> cycle?(Map.get(parents, sid), parents, MapSet.put(seen, sid))
    end
  end

  defp roster_rows(roster) do
    roster
    |> Enum.map(&normalize_roster_row/1)
    |> Enum.sort_by(& &1.sid)
    |> Enum.map(fn %{sid: sid, name: name, parent: parent} -> [sid, name, parent] end)
  end

  defp section(config, key) when is_map(config), do: Map.get(config, key, Map.get(config, Atom.to_string(key), %{}))
  defp section(config, key) when is_list(config), do: Keyword.get(config, key, [])
  defp section(_config, _key), do: []

  defp value(section, key, default) when is_map(section) and is_atom(key),
    do: Map.get(section, key, Map.get(section, Atom.to_string(key), default))

  defp value(section, key, default) when is_map(section) and is_binary(key), do: Map.get(section, key, default)
  defp value(section, key, default) when is_list(section) and is_atom(key), do: Keyword.get(section, key, default)
  defp value(_section, _key, default), do: default

  defp prefix(channel, expected),
    do: if(expected in value(channel, :channel_prefixes, ["#", "&"]), do: expected, else: expected)

  defp join_limit(channel, prefix, default) do
    limits = value(channel, :channel_join_limits, %{})

    atom_default =
      case prefix do
        "#" -> value(limits, :"#", default)
        "&" -> value(limits, :&, default)
        _ -> default
      end

    value(limits, prefix, atom_default)
  end

  defp list_limit(channel, mode, default) do
    limits = value(channel, :max_list_entries, %{})
    value(limits, mode, value(limits, Atom.to_string(mode), default))
  end

  defp add_if(errors, true, _error), do: errors
  defp add_if(errors, false, error), do: [error | errors]
end
