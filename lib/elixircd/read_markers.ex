defmodule ElixIRCd.ReadMarkers do
  @moduledoc "Account-aware read-marker policy and wire formatting."

  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ReadMarkers
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @doc "Reports whether read markers are enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.fetch_env!(:elixircd, :read_markers)[:enabled]

  @doc "Returns the persistent account or non-reassignable session owner key."
  @spec owner_key(User.t()) :: String.t() | nil
  def owner_key(%User{} = user), do: History.identity_key(user)

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
    case owner_key(user) do
      owner when is_binary(owner) -> set_for_owner(owner, target, timestamp)
      _ -> {:error, :invalid_owner}
    end
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
