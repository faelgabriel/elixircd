defmodule ElixIRCd.Command.Mode.UserModes do
  @moduledoc """
  This module includes the user modes handler.
  """

  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Tables.User

  @modes ["i", "o", "w", "Z"]
  @modes_handled_by_server_to_add ["o", "Z"]
  @modes_handled_by_server_to_remove ["Z"]

  @type mode :: String.t()
  @type mode_change :: {:add, mode()} | {:remove, mode()}

  @doc """
  Returns the string representation of the modes.
  """
  @spec display_modes([mode()]) :: String.t()
  def display_modes([]), do: ""
  def display_modes(modes), do: "+" <> Enum.join(modes, "")

  @doc """
  Returns the string representation of the mode changes.
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
  @spec apply_mode_changes(User.t(), [mode_change()]) :: {User.t(), [mode_change()]}
  def apply_mode_changes(user, validated_modes) do
    {applied_changes, new_modes} =
      Enum.reduce(validated_modes, {[], user.modes}, fn {action, mode}, acc ->
        apply_mode_change({action, mode}, acc)
      end)
      |> then(fn {applied_changes, new_modes} ->
        {Enum.reverse(applied_changes), Enum.reverse(new_modes)}
      end)

    updated_user = Users.update(user, %{modes: new_modes})

    {updated_user, applied_changes}
  end

  @spec apply_mode_change(mode_change(), {[mode_change()], [mode()]}) :: {[mode_change()], [mode()]}
  defp apply_mode_change({:add, mode}, {applied_changes, new_modes}) when mode in @modes_handled_by_server_to_add do
    # ignore modes handled by the server
    {applied_changes, new_modes}
  end

  defp apply_mode_change({:add, mode}, {applied_changes, new_modes}) do
    if Enum.member?(new_modes, mode) do
      # ignore if the mode is already set
      {applied_changes, new_modes}
    else
      {[{:add, mode} | applied_changes], [mode | new_modes]}
    end
  end

  defp apply_mode_change({:remove, mode}, {applied_changes, new_modes})
       when mode in @modes_handled_by_server_to_remove do
    {applied_changes, new_modes}
  end

  defp apply_mode_change({:remove, mode}, {applied_changes, new_modes}) do
    if Enum.member?(new_modes, mode) do
      {[{:remove, mode} | applied_changes], List.delete(new_modes, mode)}
    else
      # ignore if the mode is not set
      {applied_changes, new_modes}
    end
  end
end
