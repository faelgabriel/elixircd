defmodule ElixIRCd.Server.S2S.Projection do
  @moduledoc """
  Explicit projections from the existing C2S tables into ENP/1 rows.

  Sensitive fields, PIDs, sockets, CAP state, passwords and local rate-limit
  data are intentionally absent. Local PID-based repositories remain usable by
  C2S code; the network projection is keyed by the stable UID.
  """

  alias ElixIRCd.Server.S2S.PolicyStore
  alias ElixIRCd.Server.S2S.Schema
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping

  @doc "Projects one local user without transport or credential secrets."
  @spec user(User.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def user(user, boot, options \\ [])

  def user(%User{registered: false}, _boot, _options), do: {:error, :unregistered_user}

  def user(%User{} = value, boot, options) do
    uid = value.uid
    sid = value.home_sid || Keyword.get(options, :sid, "local")
    home_boot = value.home_boot || boot
    requested_nick = value.nick || "~" <> String.slice(uid, 0, 8)
    signon_ms = datetime_ms(value.created_at)
    policy_epoch = Keyword.get(options, :policy_epoch)
    binding_value = binding(value, policy_epoch, Keyword.get(options, :policy))

    projection = %{
      "uid" => uid,
      "home" => %{"sid" => sid, "boot" => home_boot},
      "rev" => max(value.owner_rev || 1, 1),
      "requested_nick" => requested_nick,
      "signon_ms" => max(signon_ms, 1),
      "ident" => value.ident || "unknown",
      "realhost" => value.hostname || "unknown",
      "displayhost" => value.cloaked_hostname || value.hostname || "unknown",
      "address" => address(value.ip_address),
      "secure_client" => value.transport in [:tls, :wss] or value.webirc_secure == true,
      "client_certfp" => nil,
      "modes" => modes(value.modes),
      "oper_role" => oper_role(value),
      "away" => away(value),
      "realname" => value.realname || "",
      "binding" => binding_value
    }

    if Schema.validate_row(%{"kind" => "user.put", "user" => projection}) == :ok,
      do: {:ok, projection},
      else: {:error, :invalid_user_projection}
  end

  @doc "Projects one channel incarnation and its current topic/mode registers."
  @spec channel(Channel.t(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def channel(%Channel{} = value, sid, boot, options \\ []) do
    ref = %{
      "name" => value.name,
      "born_ms" => max(value.born_ms || datetime_ms(value.created_at), 1),
      "cid" => value.cid
    }

    ensure = %{"kind" => "channel.ensure", "channel" => ref}
    stamp = Keyword.get(options, :stamp, [1, sid, boot])

    fields =
      [
        topic_field(value.topic, ref, stamp, sid)
        | Enum.flat_map(value.modes, &mode_fields(&1, ref, stamp, sid))
      ]
      |> Enum.reject(&is_nil/1)

    rows = [ensure | fields] ++ Keyword.get(options, :list_rows, [])

    if Enum.all?(rows, &(Schema.validate_row(&1) == :ok)), do: {:ok, rows}, else: {:error, :invalid_channel_projection}
  end

  @doc "Projects one complete membership set and status registers."
  @spec memberships(User.t(), [UserChannel.t()], String.t(), String.t(), keyword()) ::
          {:ok, map(), [map()]} | {:error, term()}
  def memberships(%User{} = user, records, sid, boot, options \\ []) when is_list(records) do
    uid = user.uid
    home = %{"sid" => user.home_sid || Keyword.get(options, :sid, sid), "boot" => user.home_boot || boot}
    channel_refs = Keyword.get(options, :channel_refs, %{})

    sorted_records = Enum.sort_by(records, &{&1.channel_name_key, &1.join_id || 0})

    entries =
      sorted_records
      |> Enum.with_index(1)
      |> Enum.map(fn {%UserChannel{} = record, index} ->
        %{
          "channel" => record.channel_name_key,
          "join_id" => max(record.join_id || index, 1),
          "joined_ms" => max(record.joined_ms || datetime_ms(record.created_at), 1)
        }
      end)

    cause =
      Keyword.get(options, :cause) ||
        %{
          "action" => "sync",
          "channel" => nil,
          "join_id" => nil,
          "by" => %{"server" => sid},
          "reason" => "snapshot"
        }

    revision = if entries == [], do: user.membership_rev || 0, else: max(user.membership_rev || 0, 1)

    membership = %{
      "kind" => "memberships.put",
      "uid" => uid,
      "home" => home,
      "rev" => revision,
      "entries" => entries,
      "cause" => cause
    }

    statuses =
      sorted_records
      |> Enum.zip(entries)
      |> Enum.flat_map(fn {%UserChannel{} = record, entry} ->
        Enum.map(record.modes, fn mode ->
          mode = Atom.to_string(mode)

          if mode in ~w(o v) do
            %{
              "kind" => "member.status",
              "channel" => Map.get(channel_refs, entry["channel"]),
              "uid" => uid,
              "join_id" => entry["join_id"],
              "mode" => mode,
              "enabled" => true,
              "stamp" => Keyword.get(options, :status_stamp, [1, sid, boot]),
              "setter" => %{"user" => uid}
            }
          end
        end)
      end)
      |> Enum.reject(&is_nil/1)

    rows = [membership | statuses]

    if Enum.all?(rows, &(Schema.validate_row(&1) == :ok)),
      do: {:ok, membership, statuses},
      else: {:error, :invalid_membership_projection}
  end

  defp topic_field(nil, _ref, _stamp, _sid), do: nil

  defp topic_field(topic, ref, stamp, sid) do
    %{
      "kind" => "channel.field",
      "channel" => ref,
      "field" => "topic",
      "value" => %{"text" => topic.text, "setter" => topic.setter, "set_ms" => datetime_ms(topic.set_at)},
      "stamp" => stamp,
      "setter" => %{"server" => sid}
    }
  end

  defp mode_fields(mode, ref, stamp, sid) when is_atom(mode) do
    mode = Atom.to_string(mode)

    if mode in ~w(b e I o v),
      do: [],
      else: [
        %{
          "kind" => "channel.field",
          "channel" => ref,
          "field" => "mode:" <> mode,
          "value" => true,
          "stamp" => stamp,
          "setter" => %{"server" => sid}
        }
      ]
  end

  defp mode_fields({mode, argument}, ref, stamp, sid) when is_atom(mode) do
    mode = Atom.to_string(mode)

    if mode in ~w(b e I o v),
      do: [],
      else: [
        %{
          "kind" => "channel.field",
          "channel" => ref,
          "field" => "mode:" <> mode,
          "value" => argument,
          "stamp" => stamp,
          "setter" => %{"server" => sid}
        }
      ]
  end

  defp mode_fields(_mode, _ref, _stamp, _sid), do: []

  defp modes(values) when is_list(values),
    do: values |> Enum.map(&mode_string/1) |> Enum.reject(&(&1 in ["r", "Z"])) |> Enum.uniq()

  defp modes(_values), do: []

  defp mode_string(value) when is_atom(value), do: Atom.to_string(value)
  defp mode_string(value) when is_binary(value), do: value
  defp mode_string(value), do: inspect(value)

  defp oper_role(%User{modes: modes}) do
    if :o in List.wrap(modes), do: "oper", else: nil
  end

  defp away(%User{away_message: nil}), do: nil

  defp away(%User{away_message: message, last_activity: since}) when is_binary(message),
    do: %{"text" => message, "since_ms" => max(since * 1_000, 1)}

  defp away(_user), do: nil

  defp binding(%User{identified_as: account_name}, policy_epoch)
       when is_binary(account_name) and is_binary(policy_epoch) do
    case registered_nick(account_name) do
      {:ok, %{account_id: account_id, auth_epoch: auth_epoch}}
      when is_binary(account_id) and is_integer(auth_epoch) and auth_epoch > 0 ->
        %{"account_id" => account_id, "auth_epoch" => auth_epoch, "policy_epoch" => policy_epoch}

      _ ->
        nil
    end
  end

  defp binding(%User{identified_as: account_name} = user, nil) when is_binary(account_name) do
    binding(user, configured_policy_epoch())
  end

  defp binding(_user, _policy_epoch), do: nil

  defp binding(%User{identified_as: account_name} = user, policy_epoch, policy)
       when is_binary(account_name) and is_binary(policy_epoch) and is_map(policy) do
    case public_account(policy, account_name) do
      {:ok, account_id, auth_epoch} ->
        %{"account_id" => account_id, "auth_epoch" => auth_epoch, "policy_epoch" => policy_epoch}

      :not_found ->
        binding(user, policy_epoch)
    end
  end

  defp binding(user, policy_epoch, _policy), do: binding(user, policy_epoch)

  defp public_account(%{objects: objects}, account_name) when is_map(objects) do
    key = CaseMapping.normalize(account_name)

    Enum.find_value(objects, :not_found, fn
      {{"account", _account_key},
       %{
         "canonical_name" => canonical_name,
         "account_id" => account_id,
         "auth_epoch" => auth_epoch
       }}
      when is_binary(canonical_name) and is_binary(account_id) and is_integer(auth_epoch) and auth_epoch > 0 ->
        if CaseMapping.normalize(canonical_name) == key, do: {:ok, account_id, auth_epoch}, else: nil

      _entry ->
        nil
    end)
  end

  defp public_account(_policy, _account_name), do: :not_found

  defp registered_nick(account_name) do
    if Memento.Transaction.inside?() do
      RegisteredNicks.get_by_nickname(account_name)
    else
      Memento.transaction!(fn -> RegisteredNicks.get_by_nickname(account_name) end)
    end
  end

  defp configured_policy_epoch do
    s2s = Application.get_env(:elixircd, :s2s, [])

    configured =
      case s2s do
        values when is_list(values) -> Keyword.get(values, :policy_epoch)
        values when is_map(values) -> Map.get(values, :policy_epoch, Map.get(values, "policy_epoch"))
        _ -> nil
      end

    configured || get_in(PolicyStore.read() || %{}, [:epoch])
  end

  defp address(nil), do: ""
  defp address(value) when is_tuple(value), do: value |> :inet.ntoa() |> to_string()
  defp address(value) when is_binary(value), do: value
  defp address(_value), do: ""

  defp datetime_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp datetime_ms(value) when is_integer(value), do: value
  defp datetime_ms(_value), do: System.system_time(:millisecond)
end
