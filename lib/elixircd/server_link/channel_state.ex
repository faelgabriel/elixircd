defmodule ElixIRCd.ServerLink.ChannelState do
  @moduledoc "Reads the committed local channel contribution as bounded wire records."

  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelExcept
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  @enforce_keys [:channels, :members, :lists, :invites]
  defstruct [:channels, :members, :lists, :invites]

  @type t :: %__MODULE__{
          channels: [map()],
          members: [map()],
          lists: [map()],
          invites: [map()]
        }

  @doc "Takes one Mnesia transaction snapshot and omits local-only channels and unknown users."
  @spec snapshot(map(), String.t()) :: t()
  def snapshot(users, origin) do
    Memento.transaction!(fn ->
      channels =
        Channel
        |> Memento.Query.all()
        |> Enum.filter(&String.starts_with?(&1.name, "#"))
        |> Map.new(&{&1.name_key, &1})

      identities =
        ChannelIdentity
        |> Memento.Query.all()
        |> Map.new(&{&1.name_key, &1.creator})

      %__MODULE__{
        channels:
          channels
          |> Enum.map(fn {key, channel} -> ChannelPayload.from_local(channel, Map.get(identities, key, origin)) end)
          |> sort_records(),
        members: project_members(channels, users),
        lists: project_lists(channels),
        invites: project_invites(channels, users)
      }
    end)
  end

  @doc "Returns only changed channel entries, ordered so deletes precede additions."
  @spec diff(t(), t()) :: [map()]
  def diff(%__MODULE__{} = old, %__MODULE__{} = current) do
    removals = Enum.flat_map(["invite", "member", "list", "channel"], &changes(old, current, &1, "remove"))
    upserts = Enum.flat_map(["channel", "list", "member", "invite"], &changes(old, current, &1, "upsert"))
    removals ++ upserts
  end

  defp changes(old, current, field, action) do
    old_entries = keyed_entries(old, field)
    current_entries = keyed_entries(current, field)

    entries = if action == "remove", do: old_entries, else: current_entries
    comparison = if action == "remove", do: current_entries, else: old_entries

    entries
    |> Enum.reject(fn {key, entry} ->
      case Map.fetch(comparison, key) do
        :error ->
          false

        {:ok, other} ->
          (action == "remove" and not membership_generation_changed?(field, entry, other)) or other == entry
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_key, entry} -> %{"field" => field, "action" => action, "entry" => entry} end)
  end

  defp membership_generation_changed?("member", old, current), do: old["joined_at"] != current["joined_at"]
  defp membership_generation_changed?(_field, _old, _current), do: false

  defp keyed_entries(state, field) do
    field
    |> entry_list(state)
    |> Map.new(&{entry_key(field, &1), &1})
  end

  defp entry_list("channel", state), do: state.channels
  defp entry_list("member", state), do: state.members
  defp entry_list("list", state), do: state.lists
  defp entry_list("invite", state), do: state.invites

  defp entry_key("channel", entry), do: CaseMapping.normalize(entry["name"])
  defp entry_key("member", entry), do: {CaseMapping.normalize(entry["channel"]), entry["uid"]}

  defp entry_key("list", entry),
    do: {CaseMapping.normalize(entry["channel"]), entry["kind"], Protocol.mask_key(entry["mask"])}

  defp entry_key("invite", entry), do: {CaseMapping.normalize(entry["channel"]), entry["uid"]}

  defp project_members(channels, users) do
    UserChannel
    |> Memento.Query.all()
    |> Enum.flat_map(fn membership ->
      with {:ok, channel} <- Map.fetch(channels, membership.channel_name_key),
           {:ok, %{uid: uid}} <- Map.fetch(users, membership.user_pid) do
        [ChannelPayload.member_from_local(membership, channel.name, uid)]
      else
        _ -> []
      end
    end)
    |> sort_records()
  end

  defp project_lists(channels) do
    [{ChannelBan, "b"}, {ChannelExcept, "e"}, {ChannelInvex, "I"}]
    |> Enum.flat_map(fn {table, kind} -> project_list_table(table, kind, channels) end)
    |> sort_records()
  end

  defp project_list_table(table, kind, channels) do
    table
    |> Memento.Query.all()
    |> Enum.flat_map(fn entry ->
      case Map.fetch(channels, entry.channel_name_key) do
        {:ok, channel} -> [ChannelPayload.list_from_local(entry, channel.name, kind)]
        :error -> []
      end
    end)
  end

  defp project_invites(channels, users) do
    ChannelInvite
    |> Memento.Query.all()
    |> Enum.flat_map(fn invite ->
      with {:ok, channel} <- Map.fetch(channels, invite.channel_name_key),
           {:ok, %{uid: uid}} <- Map.fetch(users, invite.user_pid) do
        [ChannelPayload.invite_from_local(invite, channel.name, uid)]
      else
        _ -> []
      end
    end)
    |> sort_records()
  end

  defp sort_records(records), do: Enum.sort_by(records, &Jason.encode!/1)
end
