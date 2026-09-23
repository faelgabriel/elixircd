defmodule ElixIRCd.ReadMarkers do
  @moduledoc "Account-aware read-marker policy and wire formatting."

  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ReadMarkers
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1]

  @max_targets_per_owner 256

  @doc "Reports whether read markers are enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.fetch_env!(:elixircd, :read_markers)[:enabled]

  @doc "Returns the persistent account or non-reassignable session owner key."
  @spec owner_key(User.t()) :: String.t() | nil
  def owner_key(%User{} = user), do: History.identity_key(user)

  @doc "Carries a session's read markers into the account when the user authenticates."
  @spec migrate_to_account(User.t(), User.t()) :: :ok
  def migrate_to_account(%User{} = anonymous_user, %User{} = authenticated_user) do
    ReadMarkers.migrate_owner(owner_key(anonymous_user), owner_key(authenticated_user), @max_targets_per_owner)
  end

  @doc "Normalizes a marker target using the configured IRC casemapping."
  @spec target_key(String.t()) :: String.t()
  def target_key(target), do: CaseMapping.normalize(target)

  @doc "Returns a user's stored timestamp for a target, when present."
  @spec get(User.t(), String.t()) :: DateTime.t() | nil
  def get(user, target) do
    with owner when is_binary(owner) <- owner_key(user),
         {:ok, marker} <- ReadMarkers.get(owner, target_key(target)) do
      marker.timestamp
    else
      _ -> nil
    end
  end

  @doc "Monotonically advances a user's marker for a target."
  @spec set(User.t(), String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, atom()}
  def set(user, target, timestamp) do
    with owner when is_binary(owner) <- owner_key(user),
         :ok <- valid_target(target),
         :ok <- target_capacity(owner, target_key(target)) do
      set_for_owner(owner, target, min_datetime(timestamp, DateTime.utc_now()))
    else
      nil -> {:error, :invalid_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_target(target) when is_binary(target) and byte_size(target) in 1..200 do
    valid? =
      if channel_name?(target) do
        byte_size(target) <= Application.fetch_env!(:elixircd, :channel)[:max_channel_name_length] + 1 and
          String.match?(target, ~r/\A[^\x00\x07\r\n ,:]+\z/u)
      else
        byte_size(target) <= Application.fetch_env!(:elixircd, :user)[:max_nick_length] and
          String.match?(target, ~r/\A[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]*\z/)
      end

    if valid?, do: :ok, else: {:error, :invalid_target}
  end

  defp valid_target(_target), do: {:error, :invalid_target}

  defp target_capacity(owner, key) do
    if match?({:ok, _}, ReadMarkers.get(owner, key)) or ReadMarkers.count_owner(owner) < @max_targets_per_owner,
      do: :ok,
      else: {:error, :target_limit}
  end

  defp min_datetime(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp set_for_owner(owner, target, timestamp) do
    key = target_key(target)

    case ReadMarkers.get(owner, key) do
      {:ok, marker} -> advance(marker, owner, key, target, timestamp)
      {:error, :read_marker_not_found} -> store(owner, key, target, timestamp)
    end
  end

  defp advance(marker, owner, key, target, timestamp) do
    if DateTime.compare(timestamp, marker.timestamp) == :lt,
      do: {:ok, marker.timestamp},
      else: store(owner, key, target, timestamp)
  end

  defp store(owner, key, target, timestamp) do
    marker = ReadMarkers.put(owner, key, target, timestamp)
    {:ok, marker.timestamp}
  end

  @doc "Builds the current MARKREAD reply for a target."
  @spec message(User.t(), String.t()) :: Message.t()
  def message(user, target) do
    value =
      case get(user, target) do
        nil -> "*"
        timestamp -> "timestamp=" <> DateTime.to_iso8601(timestamp)
      end

    %Message{command: "MARKREAD", params: [target, value]}
  end
end
