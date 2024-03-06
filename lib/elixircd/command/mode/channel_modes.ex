defmodule ElixIRCd.Command.Mode.ChannelModes do
  @moduledoc """
  This module includes the channel modes handler.
  """

  @modes ["n", "t", "s", "i", "m", "p", "k", "l", "b", "o", "v"]
  @modes_with_value_to_add ["k", "l", "b", "o", "v"]
  @modes_with_value_to_replace ["k", "l"]
  @modes_with_value_to_remove ["b", "o", "v"]
  @modes_without_value_to_remove ["k", "l"]
  @modes_list_separated ["b"]

  @type mode :: String.t() | {String.t(), String.t()}
  @type mode_change :: {:add, mode()} | {:remove, mode()}

  @doc """
  Returns the string representation of the modes.
  """
  @spec display_modes([mode()]) :: String.t()
  def display_modes(modes) do
    {flags, args} =
      Enum.reduce(modes, {[], []}, fn
        {mode, arg}, {flags, args} when mode not in @modes_list_separated -> {[mode | flags], [arg | args]}
        mode, {flags, args} when is_binary(mode) and mode not in @modes_list_separated -> {[mode | flags], args}
        _, acc -> acc
      end)

    flags = Enum.reverse(flags) |> Enum.join()
    args = Enum.reverse(args) |> Enum.join(" ")

    mode_string = if flags == "", do: "#{args}", else: "+#{flags} #{args}"
    String.trim(mode_string)
  end

  @doc """
  Returns the string representation of the mode changes.
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
  Parses the mode changes for a channel.
  """
  @spec parse_mode_changes([mode()], String.t(), [String.t()]) :: {[mode()], [mode_change()], [String.t()]}
  def parse_mode_changes(current_modes, mode_string, values) do
    changed_modes =
      handle_changed_modes(mode_string, values)

    {validated_modes, invalid_modes} =
      filter_invalid_modes(changed_modes)

    {applied_modes, new_modes} =
      filter_applied_modes(current_modes, validated_modes)

    {new_modes, applied_modes, invalid_modes}
  end

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
        {:add, [{:add, {mode, val}} | modes], rest_vals}

      mode, {:add, modes, vals} ->
        {:add, [{:add, mode} | modes], vals}

      mode, {:remove, modes, [val | rest_vals]} when mode in @modes_with_value_to_remove ->
        {:remove, [{:remove, {mode, val}} | modes], rest_vals}

      mode, {:remove, modes, vals} ->
        {:remove, [{:remove, mode} | modes], vals}
    end)
    |> then(fn {_, modes, _} -> Enum.reverse(modes) end)
  end

  @spec filter_invalid_modes([mode_change()]) :: {[mode_change()], [String.t()]}
  defp filter_invalid_modes(changed_modes) do
    changed_modes
    |> Enum.reduce({[], []}, fn
      {action, mode}, {valid_modes, invalid_modes} when action in [:add, :remove] ->
        case mode do
          {mode_flag, _val} when mode_flag in @modes -> {[{action, mode} | valid_modes], invalid_modes}
          mode_flag when mode_flag in @modes -> {[{action, mode} | valid_modes], invalid_modes}
          {mode_flag, _val} -> {valid_modes, [mode_flag | invalid_modes]}
          mode_flag -> {valid_modes, [mode_flag | invalid_modes]}
        end
    end)
    |> then(fn {valid_modes, invalid_modes} -> {Enum.reverse(valid_modes), Enum.reverse(invalid_modes)} end)
  end

  @spec filter_applied_modes([mode()], [mode_change()]) :: {[mode_change()], [mode()]}
  defp filter_applied_modes(current_modes, changed_modes) do
    Enum.reduce(changed_modes, {[], current_modes}, fn {action, mode}, acc ->
      apply_mode_change({action, mode}, acc)
    end)
    |> then(fn {applied_changes, new_modes} ->
      {Enum.reverse(applied_changes), Enum.reverse(new_modes)}
    end)
  end

  @spec apply_mode_change(mode_change(), {[mode_change()], [mode()]}) :: {[mode_change()], [mode()]}
  defp apply_mode_change({:add, mode}, {applied_changes, new_modes}) do
    mode_flag = extract_mode_flag(mode)

    cond do
      not is_tuple(mode) and mode in @modes_with_value_to_add ->
        {applied_changes, new_modes}

      mode_flag in @modes_with_value_to_replace ->
        handled_new_modes = Enum.reject(new_modes, &match?({^mode_flag, _}, &1))
        {[{:add, mode} | applied_changes], [mode | handled_new_modes]}

      true ->
        if Enum.member?(new_modes, mode) do
          {applied_changes, new_modes}
        else
          {[{:add, mode} | applied_changes], [mode | new_modes]}
        end
    end
  end

  defp apply_mode_change({:remove, mode}, {applied_changes, new_modes}) do
    mode_flag = extract_mode_flag(mode)

    if mode_flag in @modes_without_value_to_remove do
      handled_new_modes = Enum.reject(new_modes, &match?({^mode_flag, _}, &1))
      {[{:remove, mode} | applied_changes], handled_new_modes}
    else
      if Enum.member?(new_modes, mode) do
        {[{:remove, mode} | applied_changes], List.delete(new_modes, mode)}
      else
        {applied_changes, new_modes}
      end
    end
  end

  @spec extract_mode_flag(mode()) :: String.t()
  defp extract_mode_flag({mode, _val}), do: mode
  defp extract_mode_flag(mode), do: mode
end
