defmodule ElixIRCd.Server.S2S.LocalChannel do
  @moduledoc """
  Makes a reachable global channel usable by the existing C2S domain code.

  The native runtime is the network source of truth for a channel learned from
  another daemon. C2S admission still uses the canonical `Channel` and list
  tables, so this module materializes the runtime projection before local
  commands use it and removes it when the transient network channel expires.
  Materialization never publishes back to ENP; the user's membership remains
  the only local mutation that is published by that command.
  """

  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.ChannelListTombstones
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelExcept
  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Tables.ChannelListTombstone
  @doc "Returns a local channel or materializes a reachable global channel."
  @spec ensure(String.t()) :: {:ok, Channel.t()} | {:error, :channel_not_found}
  def ensure(name) when is_binary(name) do
    transaction(fn ->
      case Channels.get_by_name(name) do
        {:ok, channel} -> {:ok, channel}
        {:error, :channel_not_found} -> materialize(name)
      end
    end)
  end

  def ensure(_name), do: {:error, :channel_not_found}

  @doc "Returns the current network channel projection when one is available."
  @spec network(String.t()) :: {:ok, Channel.t()} | {:error, :channel_not_found | :unavailable}
  def network(name) when is_binary(name) do
    with {:ok, runtime} <- runtime(),
         {:ok, channel, _runtime_channel} <- View.channel(runtime, name) do
      {:ok, channel}
    else
      {:error, :channel_not_found} -> {:error, :channel_not_found}
      _ -> {:error, :unavailable}
    end
  end

  def network(_name), do: {:error, :channel_not_found}

  @doc "Materializes or refreshes a local channel from the runtime projection."
  @spec reconcile(map(), String.t()) :: :ok
  def reconcile(runtime, name) when is_map(runtime) and is_binary(name) do
    with {:ok, channel, runtime_channel} <- View.channel(runtime, name),
         false <- String.starts_with?(channel.name, "&") do
      write_materialization(channel, runtime_channel)
      :ok
    else
      true -> :ok
      {:error, :channel_not_found} -> prune(runtime, name)
    end
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  def reconcile(_runtime, _name), do: :ok

  @doc "Removes a local projection after the runtime forgot an empty channel."
  @spec prune(map(), String.t()) :: :ok
  def prune(_runtime, name) when is_binary(name) do
    transaction(fn ->
      case Channels.get_by_name(name) do
        {:ok, channel} ->
          if UserChannels.get_by_channel_name(channel.name) == [] do
            delete_materialization(channel)
          end

          :ok

        {:error, :channel_not_found} ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  def prune(_runtime, _name), do: :ok

  defp materialize(name) do
    with {:ok, runtime} <- runtime(),
         {:ok, channel, runtime_channel} <- View.channel(runtime, name),
         false <- String.starts_with?(channel.name, "&") do
      write_materialization(channel, runtime_channel)
      {:ok, channel}
    else
      true -> {:error, :channel_not_found}
      {:error, :channel_not_found} -> {:error, :channel_not_found}
      _ -> {:error, :channel_not_found}
    end
  end

  defp write_materialization(channel, runtime_channel) do
    transaction(fn ->
      if incarnation_replaced?(channel) do
        clear_materialized_incarnation(channel)
      end

      Memento.Query.write(channel)
      materialize_lists(channel.name_key, runtime_channel)
      :ok
    end)
  end

  defp incarnation_replaced?(%Channel{name: name, born_ms: born_ms, cid: cid}) do
    case Channels.get_by_name(name) do
      {:ok, %Channel{born_ms: ^born_ms, cid: ^cid}} ->
        false

      {:ok, _previous} ->
        true

      {:error, :channel_not_found} ->
        false
    end
  end

  defp clear_materialized_incarnation(%Channel{name: name, name_key: name_key}) do
    ChannelBans.get_by_channel_name_key(name_key)
    |> Enum.each(&Memento.Query.delete_record/1)

    ChannelExcepts.get_by_channel_name_key(name_key)
    |> Enum.each(&Memento.Query.delete_record/1)

    ChannelInvexes.get_by_channel_name_key(name_key)
    |> Enum.each(&Memento.Query.delete_record/1)

    ChannelListTombstones.get_by_channel_name_key(name_key)
    |> Enum.each(&Memento.Query.delete_record/1)

    UserChannels.get_by_channel_name(name)
    |> Enum.each(fn membership -> Memento.Query.write(%{membership | modes: []}) end)

    ChannelInvites.delete_by_channel_name(name)
  end

  defp delete_materialization(channel) do
    ChannelBans.get_by_channel_name_key(channel.name_key)
    |> Enum.each(&Memento.Query.delete_record/1)

    ChannelExcepts.get_by_channel_name_key(channel.name_key)
    |> Enum.each(&Memento.Query.delete_record/1)

    ChannelInvexes.get_by_channel_name_key(channel.name_key)
    |> Enum.each(&Memento.Query.delete_record/1)

    ChannelListTombstones.get_by_channel_name_key(channel.name_key)
    |> Enum.each(&Memento.Query.delete_record/1)

    ChannelInvites.delete_by_channel_name(channel.name)
    Channels.delete(channel)
  end

  defp materialize_lists(channel_name_key, runtime_channel) do
    runtime_channel
    |> Map.get(:list_slots, %{})
    |> Enum.each(fn {{mode, mask}, register} ->
      value = Map.get(register, :value, %{})
      present = Map.get(value, :present, false)
      set_by = Map.get(value, :set_by, "")
      set_ms = max(Map.get(value, :set_ms, 1), 1)

      case mode do
        "b" ->
          materialize_list(
            ChannelBan,
            ChannelBans,
            channel_name_key,
            mode,
            mask,
            present,
            set_by,
            set_ms,
            register.stamp
          )

        "e" ->
          materialize_list(
            ChannelExcept,
            ChannelExcepts,
            channel_name_key,
            mode,
            mask,
            present,
            set_by,
            set_ms,
            register.stamp
          )

        "I" ->
          materialize_list(
            ChannelInvex,
            ChannelInvexes,
            channel_name_key,
            mode,
            mask,
            present,
            set_by,
            set_ms,
            register.stamp
          )

        _ ->
          :ok
      end
    end)
  end

  defp materialize_list(module, repository, channel_name_key, mode, mask, present, set_by, set_ms, stamp) do
    delete_live(repository, channel_name_key, mask)

    if present do
      record =
        module.new(%{
          channel_name_key: channel_name_key,
          mask: mask,
          setter: set_by,
          created_at: DateTime.from_unix!(set_ms, :millisecond),
          stamp: stamp
        })

      Memento.Query.write(record)
      ChannelListTombstones.delete(channel_name_key, mode, mask)
    else
      Memento.Query.write(
        ChannelListTombstone.new(%{
          channel_name_key: channel_name_key,
          mode: mode,
          mask: mask,
          set_by: set_by,
          set_ms: set_ms,
          stamp: stamp
        })
      )
    end
  end

  defp delete_live(repository, channel_name_key, mask) do
    repository.get_by_channel_name_key(channel_name_key)
    |> Enum.filter(&(&1.mask == mask))
    |> Enum.each(&Memento.Query.delete_record/1)
  end

  defp runtime do
    case Process.whereis(Manager) do
      manager when is_pid(manager) and manager != self() ->
        View.runtime(manager)

      _ ->
        {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp transaction(fun) do
    if Memento.Transaction.inside?(), do: fun.(), else: Memento.transaction!(fun)
  end
end
