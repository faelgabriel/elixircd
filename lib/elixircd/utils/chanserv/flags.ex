defmodule ElixIRCd.Utils.Chanserv.Flags do
  @moduledoc """
  Helpers for ChanServ access flags and permission checks.
  """

  alias ElixIRCd.Tables.RegisteredChannel

  @founder_flags "VAFST"
  @supported_flags String.graphemes(@founder_flags)
  @access_levels %{
    1 => "V",
    2 => "VA",
    3 => "VAF",
    4 => "VAFS",
    5 => @founder_flags
  }

  @type flag_result :: {:ok, String.t()} | {:error, :invalid_flags}
  @type permission_result :: :ok | {:error, :access_denied}

  @doc """
  Returns the implicit founder flag set.
  """
  @spec founder_flags() :: String.t()
  def founder_flags, do: @founder_flags

  @doc """
  Returns the list of supported symbolic flags.
  """
  @spec supported_flags() :: [String.t()]
  def supported_flags, do: @supported_flags

  @doc """
  Maps a numeric access level to its corresponding symbolic flags.
  """
  @spec access_level_to_flags(integer()) :: {:ok, String.t()} | :error
  def access_level_to_flags(level) do
    case Map.fetch(@access_levels, level) do
      {:ok, flags} -> {:ok, flags}
      :error -> :error
    end
  end

  @doc """
  Returns the compatibility access level for an exact flag set.
  """
  @spec flags_to_access_level(String.t()) :: integer() | nil
  def flags_to_access_level(flags) do
    normalized_flags = normalize_flags(flags)

    Enum.find_value(@access_levels, fn {level, level_flags} ->
      if level_flags == normalized_flags, do: level
    end)
  end

  @doc """
  Returns the compatibility access level as display text.
  """
  @spec access_level_text(String.t()) :: String.t()
  def access_level_text(flags) do
    case flags_to_access_level(flags) do
      nil -> "custom"
      level -> Integer.to_string(level)
    end
  end

  @doc """
  Canonicalizes a flag string by removing duplicates and ordering flags.
  """
  @spec normalize_flags(String.t()) :: String.t()
  def normalize_flags(flags) do
    flags
    |> String.graphemes()
    |> Enum.uniq()
    |> Enum.sort_by(fn flag -> Enum.find_index(@supported_flags, &(&1 == flag)) || 999 end)
    |> Enum.join()
  end

  @doc """
  Returns whether a flag string contains only supported flags.
  """
  @spec valid_flag_string?(String.t()) :: boolean()
  def valid_flag_string?(flags) do
    flags
    |> String.graphemes()
    |> Enum.all?(&(&1 in @supported_flags))
  end

  @doc """
  Applies a direct or incremental ChanServ flag change expression.
  """
  @spec apply_flag_changes(String.t(), String.t()) :: flag_result()
  def apply_flag_changes(_existing_flags, "OFF"), do: {:ok, ""}
  def apply_flag_changes(_existing_flags, "-*"), do: {:ok, ""}

  def apply_flag_changes(existing_flags, changes) do
    cond do
      changes == "" ->
        {:ok, normalize_flags(existing_flags)}

      String.starts_with?(changes, ["+", "-"]) ->
        apply_incremental_changes(existing_flags, changes)

      valid_flag_string?(changes) ->
        {:ok, normalize_flags(changes)}

      true ->
        {:error, :invalid_flags}
    end
  end

  @doc """
  Returns whether the given account is the founder of the channel.
  """
  @spec founder?(RegisteredChannel.t(), String.t() | nil) :: boolean()
  def founder?(_channel, nil), do: false
  def founder?(channel, account_name), do: channel.founder == account_name

  @doc """
  Returns the effective flags for an account on a registered channel.
  """
  @spec flags_for_account(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) :: String.t()
  def flags_for_account(_channel, nil, _access_entries), do: ""

  def flags_for_account(channel, account_name, access_entries) do
    if founder?(channel, account_name) do
      @founder_flags
    else
      access_entries
      |> Map.get(account_name, "")
      |> normalize_flags()
    end
  end

  @doc """
  Returns whether an account has a specific flag on a channel.
  """
  @spec has_flag?(RegisteredChannel.t(), String.t() | nil, String.t(), %{optional(String.t()) => String.t()}) ::
          boolean()
  def has_flag?(channel, account_name, flag, access_entries) do
    String.contains?(flags_for_account(channel, account_name, access_entries), flag)
  end

  @doc """
  Returns whether an account may view privileged channel information.
  """
  @spec can_view_privileged_info(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) ::
          permission_result()
  def can_view_privileged_info(channel, account_name, access_entries) do
    (founder?(channel, account_name) or has_any_flag?(channel, account_name, ["V", "A", "F", "S", "T"], access_entries))
    |> permission_result()
  end

  @doc """
  Returns whether an account may manage ACCESS entries.
  """
  @spec can_manage_access(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) ::
          permission_result()
  def can_manage_access(channel, account_name, access_entries) do
    (founder?(channel, account_name) or has_any_flag?(channel, account_name, ["A", "F"], access_entries))
    |> permission_result()
  end

  @doc """
  Returns whether an account may manage FLAGS entries.
  """
  @spec can_manage_flags(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) ::
          permission_result()
  def can_manage_flags(channel, account_name, access_entries) do
    (founder?(channel, account_name) or has_flag?(channel, account_name, "F", access_entries))
    |> permission_result()
  end

  @doc """
  Returns whether an account may use ChanServ OP and DEOP.
  """
  @spec can_use_op(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) ::
          permission_result()
  def can_use_op(channel, account_name, access_entries) do
    (founder?(channel, account_name) or has_flag?(channel, account_name, "S", access_entries))
    |> permission_result()
  end

  @doc """
  Returns whether an account may use ChanServ VOICE and DEVOICE.
  """
  @spec can_use_voice(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) ::
          permission_result()
  def can_use_voice(channel, account_name, access_entries) do
    (founder?(channel, account_name) or has_flag?(channel, account_name, "V", access_entries))
    |> permission_result()
  end

  @doc """
  Returns whether an account may use ChanServ topic management commands.
  """
  @spec can_use_topic(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) ::
          permission_result()
  def can_use_topic(channel, account_name, access_entries) do
    (founder?(channel, account_name) or has_flag?(channel, account_name, "T", access_entries))
    |> permission_result()
  end

  @doc """
  Returns whether an account may use ChanServ moderation commands.
  """
  @spec can_use_moderation(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) ::
          permission_result()
  def can_use_moderation(channel, account_name, access_entries) do
    (founder?(channel, account_name) or has_flag?(channel, account_name, "S", access_entries))
    |> permission_result()
  end

  # Privilege precedence for PEACE rank and grant checks. T is deliberately low (topic-only);
  # a lone T must never outrank a broader flag set.
  @flag_precedence %{"V" => 1, "T" => 2, "A" => 3, "F" => 4, "S" => 5}
  @founder_rank 100

  @doc """
  Returns a numeric access rank suitable for comparing privileges.
  """
  @spec access_rank(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) :: non_neg_integer()
  def access_rank(channel, account_name, access_entries) do
    if founder?(channel, account_name) do
      @founder_rank
    else
      known_flags =
        flags_for_account(channel, account_name, access_entries)
        |> String.graphemes()
        |> Enum.filter(&Map.has_key?(@flag_precedence, &1))

      highest = known_flags |> Enum.map(&@flag_precedence[&1]) |> Enum.max(fn -> 0 end)

      highest * 10 + length(known_flags)
    end
  end

  @doc """
  Returns whether the granter may set the target's flags to the new value.

  A granter can never touch an account holding flags they lack themselves,
  nor grant flags they do not hold. Founders hold every flag implicitly.
  """
  @spec may_grant?(RegisteredChannel.t(), String.t() | nil, String.t(), String.t(), %{
          optional(String.t()) => String.t()
        }) :: boolean()
  def may_grant?(channel, granter_account, target_current_flags, new_flags, access_entries) do
    granter_flags = flags_for_account(channel, granter_account, access_entries)

    subset?(target_current_flags, granter_flags) and subset?(new_flags, granter_flags)
  end

  @spec subset?(String.t(), String.t()) :: boolean()
  defp subset?(flags, allowed_flags) do
    allowed_set = MapSet.new(String.graphemes(allowed_flags))

    flags
    |> String.graphemes()
    |> Enum.all?(&MapSet.member?(allowed_set, &1))
  end

  @doc """
  Canonicalizes a map of persisted access entries.
  """
  @spec normalize_access_entries(%{optional(String.t()) => String.t()}) :: %{optional(String.t()) => String.t()}
  def normalize_access_entries(access_entries) do
    Enum.into(access_entries, %{}, fn {account_name, flags} ->
      {account_name, flags |> String.upcase() |> normalize_flags()}
    end)
  end

  @doc """
  Returns the desired live channel modes for an account after a ChanServ SYNC.
  """
  @spec desired_channel_modes(RegisteredChannel.t(), String.t() | nil, %{optional(String.t()) => String.t()}) :: [
          ElixIRCd.ModeRegistry.membership_mode()
        ]
  def desired_channel_modes(channel, account_name, access_entries) do
    cond do
      founder?(channel, account_name) -> [:o]
      has_flag?(channel, account_name, "S", access_entries) -> [:o]
      has_flag?(channel, account_name, "V", access_entries) -> [:v]
      true -> []
    end
  end

  @spec has_any_flag?(RegisteredChannel.t(), String.t() | nil, [String.t()], %{optional(String.t()) => String.t()}) ::
          boolean()
  defp has_any_flag?(channel, account_name, flags, access_entries) do
    account_flags = flags_for_account(channel, account_name, access_entries)
    Enum.any?(flags, &String.contains?(account_flags, &1))
  end

  @spec permission_result(boolean()) :: permission_result()
  defp permission_result(true), do: :ok
  defp permission_result(false), do: {:error, :access_denied}

  @spec apply_incremental_changes(String.t(), String.t()) :: flag_result()
  defp apply_incremental_changes(existing_flags, changes) do
    existing_set = MapSet.new(String.graphemes(existing_flags))

    Enum.reduce_while(String.graphemes(changes), {:ok, existing_set, nil}, fn character, {:ok, flags, mode} ->
      cond do
        character in ["+", "-"] -> {:cont, {:ok, flags, character}}
        character not in @supported_flags or is_nil(mode) -> {:halt, {:error, :invalid_flags}}
        mode == "+" -> {:cont, {:ok, MapSet.put(flags, character), mode}}
        mode == "-" -> {:cont, {:ok, MapSet.delete(flags, character), mode}}
      end
    end)
    |> case do
      {:ok, updated_flags, _mode} ->
        normalized_flags =
          updated_flags
          |> Enum.join()
          |> normalize_flags()

        {:ok, normalized_flags}

      {:error, :invalid_flags} ->
        {:error, :invalid_flags}
    end
  end
end
