defmodule ElixIRCd.Commands.Mode.UserModes do
  @moduledoc """
  This module includes the user modes handler.
  """

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1]

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User

  @modes ["B", "g", "H", "i", "O", "r", "R", "w", "Z"]
  @modes_handled_by_server_to_add ["O", "r", "Z"]
  @modes_handled_by_server_to_remove ["O", "r", "Z"]
  @modes_restricted_to_operators ["H"]

  @type mode :: String.t()
  @type mode_change :: {:add, mode()} | {:remove, mode()}

  @doc """
  Returns the supported modes.
  """
  @spec modes :: [String.t()]
  def modes, do: @modes

  @doc """
  Returns the operator-only modes.
  """
  @spec modes_restricted_to_operators :: [String.t()]
  def modes_restricted_to_operators, do: @modes_restricted_to_operators

  @doc """
  Returns the string representation of the modes for a user.
  Filters operator-only modes if the user is not an operator.
  """
  @spec display_modes(User.t(), [mode()]) :: String.t()
  def display_modes(_user, []), do: ""

  def display_modes(user, modes) do
    filtered_modes =
      if irc_operator?(user), do: modes, else: Enum.reject(modes, &(&1 in @modes_restricted_to_operators))

    "+" <> Enum.join(filtered_modes, "")
  end

  @doc """
  Returns the string representation of the mode changes for a user.
  """
  @spec display_mode_changes([mode_change()]) :: String.t()
  def display_mode_changes(applied_modes) do
    {mode_string, _} =
      Enum.reduce(applied_modes, {"", :none}, fn
        {:add, mode}, {mode_str, :add} -> {"#{mode_str}#{mode}", :add}
        {:remove, mode}, {mode_str, :remove} -> {"#{mode_str}#{mode}", :remove}
        {:add, mode}, {mode_str, _} -> {"#{mode_str}+#{mode}", :add}
        {:remove, mode}, {mode_str, _} -> {"#{mode_str}-#{mode}", :remove}
      end)

    mode_string
  end

  @doc """
  Parses the mode changes for a user.
  """
  @spec parse_mode_changes(String.t()) :: {[mode_change()], [String.t()]}
  def parse_mode_changes(mode_string) do
    prefix_mode_string_if_needed(mode_string)
    |> handle_changed_modes()
    |> filter_changed_modes()
  end

  @spec prefix_mode_string_if_needed(String.t()) :: String.t()
  defp prefix_mode_string_if_needed("+" <> _ = mode_string), do: mode_string
  defp prefix_mode_string_if_needed("-" <> _ = mode_string), do: mode_string
  defp prefix_mode_string_if_needed(mode_string), do: "+#{mode_string}"

  @spec handle_changed_modes(String.t()) :: [mode_change()]
  defp handle_changed_modes(mode_string) do
    mode_string
    |> String.graphemes()
    |> Enum.reduce({:none, []}, fn
      "+", {_, modes} -> {:add, modes}
      "-", {_, modes} -> {:remove, modes}
      mode, {:add, modes} -> {:add, [{:add, mode} | modes]}
      mode, {:remove, modes} -> {:remove, [{:remove, mode} | modes]}
    end)
    |> then(fn {_, modes} -> Enum.reverse(modes) end)
  end

  @spec filter_changed_modes([mode_change()]) :: {[mode_change()], [String.t()]}
  defp filter_changed_modes(changed_modes) do
    changed_modes
    |> Enum.reduce({[], []}, fn
      {action, mode}, {valid_modes, invalid_modes} when action in [:add, :remove] ->
        case mode do
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
    Enum.any?(mode_changes, &match?({:remove, "O"}, &1))
  end

  @spec has_or_adding_h_mode?(User.t(), [mode_change()]) :: boolean()
  defp has_or_adding_h_mode?(user, mode_changes) do
    "H" in user.modes or Enum.any?(mode_changes, &match?({:add, "H"}, &1))
  end

  @spec process_mode_changes(User.t(), [mode_change()]) :: {[mode_change()], [mode()]}
  defp process_mode_changes(user, final_modes) do
    final_modes
    |> Enum.reduce({[], user.modes}, fn mode_change, acc ->
      apply_mode_change(mode_change, acc)
    end)
    |> then(fn {applied_changes, new_modes} ->
      {Enum.reverse(applied_changes), Enum.reverse(new_modes)}
    end)
  end

  @spec apply_mode_change(mode_change(), {[mode_change()], [mode()]}) :: {[mode_change()], [mode()]}
  defp apply_mode_change({:add, mode}, {applied_changes, new_modes}) when mode in @modes_handled_by_server_to_add do
    {applied_changes, new_modes}
  end

  defp apply_mode_change({:add, mode} = mode_change, {applied_changes, new_modes}) do
    case mode in new_modes do
      true -> {applied_changes, new_modes}
      false -> {[mode_change | applied_changes], [mode | new_modes]}
    end
  end

  defp apply_mode_change({:remove, mode}, {applied_changes, new_modes})
       when mode in @modes_handled_by_server_to_remove do
    {applied_changes, new_modes}
  end

  defp apply_mode_change({:remove, mode} = mode_change, {applied_changes, new_modes}) do
    case mode in new_modes do
      true -> {[mode_change | applied_changes], List.delete(new_modes, mode)}
      false -> {applied_changes, new_modes}
    end
  end
end
