defmodule ElixIRCd.ServerLink.NickReconciler do
  @moduledoc "Renames local losers after a committed network nickname collision."

  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.NickChange
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.ServerLink.NickAuthority
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.Utils.CaseMapping

  @max_attempts 64

  @doc "Applies deterministic collision resolution to local registered users after remote commit."
  @spec reconcile(Replica.t(), String.t(), :all | [String.t()]) :: :ok
  def reconcile(%Replica{} = replica, local_id, nicknames \\ :all) do
    claims = selected_claims(replica, nicknames)
    if claims != [], do: reconcile_claims(replica, local_id, claims)
    :ok
  end

  defp reconcile_claims(replica, local_id, claims) do
    occupied = MapSet.new(replica.users, fn {_identity, user} -> CaseMapping.normalize(user["nick"]) end)

    Observability.transaction(fn ->
      Enum.each(claims, &reconcile_claim(&1, local_id, occupied))
    end)
  end

  defp selected_claims(replica, :all) do
    replica.nick_keys
    |> Enum.sort()
    |> Enum.map(fn {_nick_key, identity} -> claim_for(replica, identity) end)
  end

  defp selected_claims(replica, nicknames) do
    nicknames
    |> Enum.map(&CaseMapping.normalize/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn key ->
      case Map.fetch(replica.nick_keys, key) do
        {:ok, identity} -> [claim_for(replica, identity)]
        :error -> []
      end
    end)
  end

  defp claim_for(replica, {origin, _uid} = identity) do
    NickAuthority.from_wire(origin, Map.fetch!(replica.users, identity))
  end

  defp reconcile_claim(%NickAuthority{} = remote, local_id, occupied) do
    case Users.get_by_nick(remote.nick_key) do
      {:ok, %{registered: true, pid: pid} = local} when is_pid(pid) ->
        if NickAuthority.rank(remote) < NickAuthority.rank(NickAuthority.from_local(local_id, local)) do
          rename_or_disconnect(local, occupied)
        end

      _ ->
        :ok
    end
  end

  defp rename_or_disconnect(local, occupied) do
    case available_nick(occupied, @max_attempts) do
      {:ok, nick} ->
        NickChange.change(local, nick)
        Observability.defer_effect(fn -> NickEnforcement.cancel(local.pid) end)

      :error ->
        Dispatcher.disconnect(local, "Nickname collision: no replacement nickname available")
    end
  end

  defp available_nick(_occupied, 0), do: :error

  defp available_nick(occupied, remaining) do
    max_length = Application.fetch_env!(:elixircd, :user)[:max_nick_length]
    candidate = random_nick(max_length)
    key = CaseMapping.normalize(candidate)

    with false <- MapSet.member?(occupied, key),
         {:error, :user_not_found} <- Users.get_by_nick(candidate),
         {:error, :registered_nick_not_found} <- RegisteredNicks.get_by_nickname(candidate) do
      {:ok, candidate}
    else
      _ -> available_nick(occupied, remaining - 1)
    end
  end

  defp random_nick(1) do
    <<number>> = :crypto.strong_rand_bytes(1)
    <<?A + rem(number, 26)>>
  end

  defp random_nick(max_length) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    String.slice("G" <> suffix, 0, max_length)
  end
end
