defmodule ElixIRCd.Commands.Mode.UserModes do
  @moduledoc """
  This module includes the user modes handler.
  """

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1]

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User

  @modes ["B", "g", "H", "i", "o", "r", "R", "s", "w", "Z"]
  @modes_handled_by_server_to_add ["o", "r", "Z"]
  @modes_handled_by_server_to_remove ["r", "Z"]
  @modes_restricted_to_operators ["H", "s"]
  @modes_with_value_to_add ["s"]
  @modes_with_value_to_replace ["s"]
  @modes_with_value_to_remove ["s"]

  @snomask_letters ["c", "k", "o", "s", "f", "n", "x", "g", "d", "j", "l", "q"]

  @type mode :: String.t() | {String.t(), String.t()}
  @type mode_change :: {:add, mode()} | {:remove, mode()}

  @doc """
  Returns the supported modes.
  """
  @spec modes :: [String.t()]
  def modes, do: @modes

  @doc """
  Returns the supported non-parameterized modes (for ISUPPORT and RPL_MYINFO).
  """
  @spec non_parameterized_modes :: [String.t()]
  def non_parameterized_modes do
    parameterized_modes = ["s"]  # Add other parameterized modes here if needed
    @modes |> Enum.reject(&(&1 in parameterized_modes))
  end

  @doc """
  Returns the operator-only modes.
  """
  @spec modes_restricted_to_operators :: [String.t()]
  def modes_restricted_to_operators, do: @modes_restricted_to_operators

  @doc """
  Returns the supported snomask letters.
  """
  @spec snomask_letters :: [String.t()]
  def snomask_letters, do: @snomask_letters

  @doc """
  Returns the string representation of the modes for a user.
  Filters operator-only modes if the user is not an operator.
  """
  @spec display_modes(User.t(), [mode()]) :: String.t()
  def display_modes(_user, []), do: ""

  def display_modes(user, modes) do
    filtered_modes =
      if irc_operator?(user), do: modes, else: Enum.reject(modes, &is_operator_only_mode?/1)

    # Check for snomask modes - if present, display only snomask
    snomask_modes = Enum.filter(filtered_modes, fn
      {"s", _} -> true
      _ -> false
    end)

    case snomask_modes do
      [{"s", snomask_value}] ->
        # Display only snomask in special format
        "+s=#{snomask_value}"
      [] ->
        # No snomask modes, display all other modes normally
        flags = Enum.reject(filtered_modes, fn {"s", _} -> true; _ -> false end)
                |> Enum.join("")
        "+#{flags}"
      _ ->
        # Multiple snomask modes (shouldn't happen), fallback to general formatting
        {flags, args} =
          Enum.reduce(filtered_modes, {[], []}, fn
            {mode, arg}, {flags, args} -> {[mode | flags], [arg | args]}
            mode, {flags, args} -> {[mode | flags], args}
          end)

        flags = Enum.reverse(flags) |> Enum.join()
        args = Enum.reverse(args)

        case args do
          [] -> "+#{flags}"
          _ -> "+#{flags} #{Enum.join(args, " ")}"
        end
    end
  end

  @spec is_operator_only_mode?(mode()) :: boolean()
  defp is_operator_only_mode?({mode, _arg}), do: mode in @modes_restricted_to_operators
  defp is_operator_only_mode?(mode), do: mode in @modes_restricted_to_operators

  @doc """
  Returns the string representation of the mode changes for a user.
  """
  @spec display_mode_changes([mode_change()]) :: String.t()
  def display_mode_changes(applied_modes) do
    {mode_string, args, _} =
      Enum.reduce(applied_modes, {"", [], :none}, fn
        {:add, {mode, arg}}, {mode_str, args, :add} -> {"#{mode_str}#{mode}", args ++ [arg], :add}
        {:add, mode}, {mode_str, args, :add} -> {"#{mode_str}#{mode}", args, :add}
        {:remove, {mode, arg}}, {mode_str, args, :remove} -> {"#{mode_str}#{mode}", args ++ [arg], :remove}
        {:remove, mode}, {mode_str, args, :remove} -> {"#{mode_str}#{mode}", args, :remove}
        {:add, {mode, arg}}, {mode_str, args, _} -> {"#{mode_str}+#{mode}", args ++ [arg], :add}
        {:add, mode}, {mode_str, args, _} -> {"#{mode_str}+#{mode}", args, :add}
        {:remove, {mode, arg}}, {mode_str, args, _} -> {"#{mode_str}-#{mode}", args ++ [arg], :remove}
        {:remove, mode}, {mode_str, args, _} -> {"#{mode_str}-#{mode}", args, :remove}
      end)

    arg_string = Enum.join(args, " ")

    case arg_string do
      "" -> mode_string
      _ -> "#{mode_string} #{arg_string}"
    end
  end

  @doc """
  Parses the mode changes for a user.
  """
  @spec parse_mode_changes(String.t()) :: {[mode_change()], [String.t()]}
  def parse_mode_changes(mode_string) do
    parse_mode_changes(mode_string, [])
  end

  @spec parse_mode_changes(String.t(), [String.t()]) :: {[mode_change()], [String.t()]}
  def parse_mode_changes(mode_string, values) do
    prefix_mode_string_if_needed(mode_string)
    |> handle_changed_modes(values)
    |> filter_changed_modes()
  end

  @spec prefix_mode_string_if_needed(String.t()) :: String.t()
  defp prefix_mode_string_if_needed("+" <> _ = mode_string), do: mode_string
  defp prefix_mode_string_if_needed("-" <> _ = mode_string), do: mode_string
  defp prefix_mode_string_if_needed(mode_string), do: "+#{mode_string}"

  @spec handle_changed_modes(String.t(), [String.t()]) :: [mode_change()]
  defp handle_changed_modes(mode_string, values) do
    mode_string
    |> String.graphemes()
    |> Enum.reduce({:none, [], values}, fn
      "+", {_, modes, vals} ->
        {:add, modes, vals}

      "-", {_, modes, vals} ->
        {:remove, modes, vals}

      mode, {:add, modes, [val | rest_vals]} when mode in @modes_with_value_to_add ->
        validated_val = validate_mode_param(mode, val)
        case validated_val do
          nil -> {:add, modes, rest_vals}  # Skip invalid parameters
          valid_val -> {:add, [{:add, {mode, valid_val}} | modes], rest_vals}
        end

      mode, {:add, modes, vals} ->
        {:add, [{:add, mode} | modes], vals}

      mode, {:remove, modes, [val | rest_vals]} when mode in @modes_with_value_to_remove ->
        validated_val = validate_mode_param(mode, val)
        case validated_val do
          nil -> {:remove, modes, rest_vals}  # Skip invalid parameters
          valid_val -> {:remove, [{:remove, {mode, valid_val}} | modes], rest_vals}
        end

      mode, {:remove, modes, vals} ->
        {:remove, [{:remove, mode} | modes], vals}
    end)
    |> then(fn {_, modes, _} -> Enum.reverse(modes) end)
  end

  @spec filter_changed_modes([mode_change()]) :: {[mode_change()], [String.t()]}
  defp filter_changed_modes(changed_modes) do
    changed_modes
    |> Enum.reduce({[], []}, fn
      {action, mode}, {valid_modes, invalid_modes} when action in [:add, :remove] ->
        case mode do
          {mode_flag, _val} when mode_flag in @modes -> {[{action, mode} | valid_modes], invalid_modes}
          mode_flag when mode_flag in @modes -> {[{action, mode} | valid_modes], invalid_modes}
          mode_flag -> {valid_modes, [mode_flag | invalid_modes]}
        end
    end)
    |> then(fn {valid_modes, invalid_modes} -> {Enum.reverse(valid_modes), Enum.reverse(invalid_modes)} end)
  end

  @doc """
  Applies the mode changes for a user.
  """
  @spec apply_mode_changes(User.t(), [mode_change()]) :: {User.t(), [mode_change()], [mode_change()]}
  def apply_mode_changes(user, mode_changes) do
    with {valid_modes, unauthorized_modes} <- validate_operator_permissions(user, mode_changes),
         final_modes <- maybe_add_h_removal(user, valid_modes),
         {applied_changes, new_modes} <- process_mode_changes(user, final_modes),
         updated_user <- Users.update(user, %{modes: new_modes}) do
      {updated_user, applied_changes, unauthorized_modes}
    end
  end

  @spec validate_operator_permissions(User.t(), [mode_change()]) :: {[mode_change()], [mode_change()]}
  defp validate_operator_permissions(user, mode_changes) do
    Enum.split_with(mode_changes, fn
      {_, {mode, _param}} when mode in @modes_restricted_to_operators -> irc_operator?(user)
      {_, mode} when mode in @modes_restricted_to_operators -> irc_operator?(user)
      {_, _mode} -> true
    end)
  end

  @spec maybe_add_h_removal(User.t(), [mode_change()]) :: [mode_change()]
  defp maybe_add_h_removal(user, valid_modes) do
    case should_remove_h_mode?(user, valid_modes) do
      true -> valid_modes ++ [{:remove, "H"}]
      false -> valid_modes
    end
  end

  @spec should_remove_h_mode?(User.t(), [mode_change()]) :: boolean()
  defp should_remove_h_mode?(user, mode_changes) do
    with true <- removing_operator?(mode_changes),
         true <- has_or_adding_h_mode?(user, mode_changes) do
      true
    else
      _ -> false
    end
  end

  @spec removing_operator?([mode_change()]) :: boolean()
  defp removing_operator?(mode_changes) do
    Enum.any?(mode_changes, &match?({:remove, "o"}, &1))
  end

  @spec has_or_adding_h_mode?(User.t(), [mode_change()]) :: boolean()
  defp has_or_adding_h_mode?(user, mode_changes) do
    has_h_mode?(user.modes) or Enum.any?(mode_changes, &match?({:add, "H"}, &1))
  end

  @spec has_h_mode?([mode()]) :: boolean()
  defp has_h_mode?(modes) do
    Enum.any?(modes, fn
      "H" -> true
      {"H", _} -> true
      _ -> false
    end)
  end

  @spec process_mode_changes(User.t(), [mode_change()]) :: {[mode_change()], [mode()]}
  defp process_mode_changes(user, final_modes) do
    final_modes
    |> Enum.reduce({[], user.modes}, fn mode_change, acc ->
      apply_mode_change(mode_change, acc)
    end)
    |> then(fn {applied_changes, new_modes} ->
      {Enum.reverse(applied_changes), new_modes}
    end)
  end

  @spec apply_mode_change(mode_change(), {[mode_change()], [mode()]}) :: {[mode_change()], [mode()]}
  defp apply_mode_change({:add, mode}, {applied_changes, new_modes}) when mode in @modes_handled_by_server_to_add do
    {applied_changes, new_modes}
  end

  defp apply_mode_change({:add, {mode, param}}, {applied_changes, new_modes}) do
    new_mode = {mode, param}
    cond do
      mode in @modes_with_value_to_replace and mode_already_set?(mode, new_modes) ->
        # Remove existing mode and add new one with new value (replacement)
        filtered_modes = remove_mode_from_list(mode, new_modes)
        {[{:add, new_mode} | applied_changes], filtered_modes ++ [new_mode]}

      mode_already_set?(new_mode, new_modes) ->
        {applied_changes, new_modes}

      true ->
        # Normal addition (goes at end)
        {[{:add, new_mode} | applied_changes], new_modes ++ [new_mode]}
    end
  end

  defp apply_mode_change({:add, mode} = mode_change, {applied_changes, new_modes}) do
    case mode_already_set?(mode, new_modes) do
      true -> {applied_changes, new_modes}
      false -> {[mode_change | applied_changes], new_modes ++ [mode]}
    end
  end

  defp apply_mode_change({:remove, mode}, {applied_changes, new_modes})
       when mode in @modes_handled_by_server_to_remove do
    {applied_changes, new_modes}
  end

  defp apply_mode_change({:remove, mode} = mode_change, {applied_changes, new_modes}) do
    case mode_already_set?(mode, new_modes) do
      true ->
        filtered_modes = remove_mode_from_list(mode, new_modes)
        {[mode_change | applied_changes], filtered_modes}
      false ->
        {applied_changes, new_modes}
    end
  end

  defp apply_mode_change({:remove, {mode, param}} = mode_change, {applied_changes, new_modes}) do
    case mode_already_set?({mode, param}, new_modes) do
      true ->
        filtered_modes = remove_mode_from_list({mode, param}, new_modes)
        {[mode_change | applied_changes], filtered_modes}
      false ->
        {applied_changes, new_modes}
    end
  end

  @spec mode_already_set?(mode(), [mode()]) :: boolean()
  defp mode_already_set?(target_mode, modes) do
    Enum.any?(modes, fn mode -> modes_match?(mode, target_mode) end)
  end

  @spec modes_match?(mode(), mode()) :: boolean()
  defp modes_match?(mode1, mode2) when mode1 == mode2, do: true
  defp modes_match?({mode_flag, _}, mode_flag), do: true
  defp modes_match?(mode_flag, {mode_flag, _}), do: true
  defp modes_match?(_, _), do: false

  @spec remove_mode_from_list(mode(), [mode()]) :: [mode()]
  defp remove_mode_from_list(target_mode, modes) do
    Enum.reject(modes, fn mode -> modes_match?(mode, target_mode) end)
  end

  @spec validate_mode_param(String.t(), String.t()) :: String.t() | nil
  defp validate_mode_param("s", param) do
    # Validate and normalize snomask parameter
    normalize_snomask_param(param)
  end

  defp validate_mode_param(_mode, param), do: param

  @spec normalize_snomask_param(String.t()) :: String.t() | nil
  defp normalize_snomask_param(param) do
    # Check if param contains any +/- parsing logic
    if String.contains?(param, "+") or String.contains?(param, "-") do
      # Parse with +/- logic
      {_, final_acc} =
        param
        |> String.graphemes()
        |> Enum.reduce({:add, []}, fn
          "+", {_, acc} -> {:add, acc}
          "-", {_, acc} -> {:remove, acc}
          char, {:add, acc} when char in @snomask_letters ->
            {:add, [char | acc]}
          char, {:remove, acc} when char in @snomask_letters ->
            {:remove, Enum.reject(acc, &(&1 == char))}
          _char, {action, acc} ->
            {action, acc}  # Invalid chars are ignored
        end)

      unique_chars = final_acc |> Enum.uniq() |> Enum.sort()
      case unique_chars do
        [] -> nil
        chars -> Enum.join(chars, "")
      end
    else
      # Simple validation - only keep valid snomask letters
      valid_chars =
        param
        |> String.graphemes()
        |> Enum.filter(&(&1 in @snomask_letters))
        |> Enum.uniq()
        |> Enum.sort()

      case valid_chars do
        [] -> nil
        chars -> Enum.join(chars, "")
      end
    end
  end

  @doc """
  Get users with a specific snomask.
  """
  @spec get_users_with_snomask(String.t()) :: [User.t()]
  def get_users_with_snomask(snomask) do
    Users.get_all()
    |> Enum.filter(fn user ->
      user.registered and has_snomask?(user.modes, snomask)
    end)
  end

  @spec has_snomask?([mode()], String.t()) :: boolean()
  defp has_snomask?(modes, target_snomask) do
    Enum.any?(modes, fn
      {"s", snomask_value} -> String.contains?(snomask_value, target_snomask)
      _ -> false
    end)
  end
end
