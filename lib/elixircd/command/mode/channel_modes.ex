defmodule ElixIRCd.Command.Mode.ChannelModes do
  @moduledoc """
  This module includes the channel modes handler.
  """

  alias ElixIRCd.Repository.ChannelBans
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan

  @modes ["n", "t", "s", "i", "m", "p", "k", "l", "b", "o", "v"]
  @modes_with_value_to_add ["k", "l", "b", "o", "v"]
  @modes_with_value_to_replace ["k", "l"]
  @modes_with_value_to_remove ["b", "o", "v"]
  @modes_without_value_to_remove ["k", "l"]
  @modes_for_user_channel ["o", "v"]
  @modes_for_channel_ban ["b"]

  @type mode :: String.t() | {String.t(), String.t()}
  @type mode_change :: {:add, mode()} | {:remove, mode()}

  @doc """
  Returns the string representation of the modes.
  """
  @spec display_modes([mode()]) :: String.t()
  def display_modes(modes) do
    {flags, args} =
      Enum.reduce(modes, {[], []}, fn
        {mode, arg}, {flags, args} -> {[mode | flags], [arg | args]}
        mode, {flags, args} -> {[mode | flags], args}
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
  @spec parse_mode_changes(String.t(), [String.t()]) :: {[mode_change()], [String.t()]}
  # TODO: return the modes that are missing values and that's required
  def parse_mode_changes(mode_string, values) do
    handle_changed_modes(mode_string, values)
    |> filter_invalid_modes()
  end

  # TODO: without a "+" at the beginning, force it by concating it to the mode_string
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

  @spec apply_mode_changes(Channel.t(), [mode_change()]) :: {[mode_change()], Channel.t()}
  def apply_mode_changes(channel, validated_modes) do
    {applied_changes, new_modes} =
      Enum.reduce(validated_modes, {[], channel.modes}, fn {action, mode}, acc ->
        apply_mode_change(channel, {action, mode}, acc)
      end)
      |> then(fn {applied_changes, new_modes} ->
        {Enum.reverse(applied_changes), Enum.reverse(new_modes)}
      end)

    updated_channel = Channels.update(channel, %{modes: new_modes})

    {applied_changes, updated_channel}
  end

  @spec apply_mode_change(Channel.t(), mode_change(), {[mode_change()], [mode()]}) :: {[mode_change()], [mode()]}
  defp apply_mode_change(channel, {:add, mode} = mode_change, {applied_changes, new_modes}) do
    mode_flag = extract_mode_flag(mode)

    cond do
      mode_flag in @modes_for_user_channel ->
        user_channel_mode_applied?(mode_change, channel.name)
        |> case do
          true -> {[{:add, mode} | applied_changes], new_modes}
          false -> {applied_changes, new_modes}
        end

      mode_flag in @modes_for_channel_ban ->
        channel_ban_mode_applied?(mode_change, channel.name)
        |> case do
          true -> {[{:add, mode} | applied_changes], new_modes}
          false -> {applied_changes, new_modes}
        end

      mode_flag in @modes_with_value_to_replace ->
        handled_new_modes = Enum.reject(new_modes, &match?({^mode_flag, _}, &1))
        {[{:add, mode} | applied_changes], [mode | handled_new_modes]}

      # ignore if the mode is already set
      Enum.member?(new_modes, mode) ->
        {applied_changes, new_modes}

      true ->
        {[{:add, mode} | applied_changes], [mode | new_modes]}
    end
  end

  defp apply_mode_change(channel, {:remove, mode} = mode_change, {applied_changes, new_modes}) do
    mode_flag = extract_mode_flag(mode)

    cond do
      mode_flag in @modes_for_user_channel and @modes_with_value_to_remove ->
        user_channel_mode_applied?(mode_change, channel.name)
        |> case do
          true -> {[{:remove, mode} | applied_changes], new_modes}
          false -> {applied_changes, new_modes}
        end

      mode_flag in @modes_for_channel_ban and @modes_with_value_to_remove ->
        channel_ban_mode_applied?(mode_change, channel.name)
        |> case do
          true -> {[{:remove, mode} | applied_changes], new_modes}
          false -> {applied_changes, new_modes}
        end

      mode_flag in @modes_without_value_to_remove ->
        handled_new_modes = Enum.reject(new_modes, &match?({^mode_flag, _}, &1))
        {[{:remove, mode} | applied_changes], handled_new_modes}

      Enum.member?(new_modes, mode) ->
        {[{:remove, mode} | applied_changes], List.delete(new_modes, mode)}

      # ignore if the mode is not set
      true ->
        {applied_changes, new_modes}
    end
  end

  @spec extract_mode_flag(mode()) :: String.t()
  defp extract_mode_flag({mode, _val}), do: mode
  defp extract_mode_flag(mode), do: mode

  @spec user_channel_mode_applied?(mode_change(), String.t()) :: boolean()
  defp user_channel_mode_applied?({_action, {_mode_flag, mode_value}} = mode_change, channel_name) do
    with {:ok, user} <- Users.get_by_nick(mode_value),
         {:ok, user_channel} <- UserChannels.get_by_user_port_and_channel_name(user.port, channel_name) do
      user_channel_mode_changed?(mode_change, user_channel)
    else
      _ -> false
    end
  end

  @spec user_channel_mode_changed?(mode_change(), UserChannels.t()) :: boolean()
  defp user_channel_mode_changed?({:add, {mode_flag, _mode_value}}, user_channel) do
    if Enum.member?(user_channel.modes, mode_flag) do
      false
    else
      UserChannels.update(user_channel, %{modes: [mode_flag | user_channel.modes]})
      true
    end
  end

  defp user_channel_mode_changed?({:remove, {mode_flag, _mode_value}}, user_channel) do
    if Enum.member?(user_channel.modes, mode_flag) do
      UserChannels.update(user_channel, %{modes: List.delete(user_channel.modes, mode_flag)})
      true
    else
      false
    end
  end

  @spec channel_ban_mode_applied?(mode_change(), String.t()) :: boolean()
  defp channel_ban_mode_applied?({_action, {_mode_flag, mode_value}} = mode_change, channel_name) do
    ChannelBans.get_by_channel_name_and_mask(channel_name, mode_value)
    |> case do
      {:ok, channel_ban} -> channel_ban_mode_changed?(mode_change, channel_ban, channel_name)
      _ -> channel_ban_mode_changed?(mode_change, nil, channel_name)
    end
  end

  @spec channel_ban_mode_changed?(mode_change(), ChannelBan.t(), String.t()) :: boolean()
  defp channel_ban_mode_changed?({:add, {_mode_flag, mode_value}}, nil, channel_name) do
    ChannelBans.create(%{channel_name: channel_name, mask: mode_value, setter: "TODO"})
    true
  end

  defp channel_ban_mode_changed?({:add, _mode}, _channel_ban, _channel_name), do: false
  defp channel_ban_mode_changed?({:remove, _mode}, nil, _channel_name), do: false

  defp channel_ban_mode_changed?({:remove, _mode}, channel_ban, _channel_name) do
    ChannelBans.delete(channel_ban)
    true
  end
end
