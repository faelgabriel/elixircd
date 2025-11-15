defmodule ElixIRCd.Commands.Mode.ChannelModes do
  @moduledoc """
  This module handles channel mode operations.

  Channel modes control various aspects of channel behavior and user permissions.
  """

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, normalize_mask: 1, irc_operator?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @modes ["b", "C", "c", "d", "i", "j", "k", "l", "m", "M", "n", "O", "o", "p", "r", "R", "s", "t", "T", "u", "v", "z"]
  @modes_with_value_to_add ["b", "d", "j", "k", "l", "o", "v"]
  @modes_with_value_to_replace ["d", "j", "k", "l"]
  @modes_with_value_to_remove ["b", "o", "v"]
  @modes_with_value_as_integer ["d", "l"]
  @modes_without_value_to_remove ["d", "j", "k", "l"]
  @modes_for_user_channel ["o", "v"]
  @modes_for_channel_ban ["b"]
  @modes_as_listing ["b"]
  @modes_requiring_irc_operator ["O"]

  @type mode :: String.t() | {String.t(), String.t()}
  @type mode_change :: {:add, mode()} | {:remove, mode()}

  @doc """
  Returns the supported modes.
  """
  @spec modes :: [String.t()]
  def modes, do: @modes

  @doc """
  Returns the string representation of the modes.
  """
  @spec display_modes([mode()]) :: String.t()
  def display_modes([]), do: ""

  def display_modes(modes) do
    {flags, args} =
      Enum.reduce(modes, {[], []}, fn
        {mode, arg}, {flags, args} -> {[mode | flags], [arg | args]}
        mode, {flags, args} -> {[mode | flags], args}
      end)

    flags = Enum.reverse(flags) |> Enum.join()
    args = Enum.reverse(args) |> Enum.join(" ")

    String.trim("+#{flags} #{args}")
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
  Filters the mode changes for a channel by valid, listing and missing value modes.
  """
  @spec filter_mode_changes([mode_change()]) :: {[mode_change()], [String.t()], [String.t()]}
  def filter_mode_changes(validated_modes) do
    {updated_validated_modes, missing_value_modes} = filter_missing_value_modes(validated_modes)
    {updated_missing_value_modes, listing_modes} = filter_listing_modes(missing_value_modes)

    {updated_validated_modes, listing_modes, updated_missing_value_modes}
  end

  @spec filter_missing_value_modes([mode_change()]) :: {[mode_change()], [String.t()]}
  defp filter_missing_value_modes(changed_modes) do
    changed_modes
    |> Enum.reduce({[], []}, fn
      mode_change, {valid_modes, missing_value_modes} ->
        case mode_change do
          {:add, mode} when is_binary(mode) and mode in @modes_with_value_to_add ->
            {valid_modes, [mode | missing_value_modes]}

          {:remove, mode} when is_binary(mode) and mode in @modes_with_value_to_remove ->
            {valid_modes, [mode | missing_value_modes]}

          mode_change ->
            {[mode_change | valid_modes], missing_value_modes}
        end
    end)
    |> then(fn {valid_modes, missing_value_modes} -> {Enum.reverse(valid_modes), Enum.reverse(missing_value_modes)} end)
  end

  # Listing modes are based on modes that require a value to be set but are not set in the mode changes,
  # from the `missing_value_modes` list.
  @spec filter_listing_modes([String.t()]) :: {[String.t()], [String.t()]}
  defp filter_listing_modes(missing_value_modes) do
    missing_value_modes
    |> Enum.reduce({[], []}, fn
      mode, {missing_values, listing_modes} ->
        if mode in @modes_as_listing do
          {missing_values, [mode | listing_modes]}
        else
          {[mode | missing_values], listing_modes}
        end
    end)
    |> then(fn {missing_values, listing_modes} ->
      {Enum.reverse(missing_values), Enum.reverse(listing_modes |> Enum.uniq())}
    end)
  end

  @doc """
  Applies the mode changes for a channel.
  """
  @spec apply_mode_changes(User.t(), Channel.t(), [mode_change()]) :: {Channel.t(), [mode_change()]}
  def apply_mode_changes(user, channel, validated_modes) do
    {applied_changes, new_modes} =
      Enum.reduce(validated_modes, {[], channel.modes}, fn {action, mode}, acc ->
        apply_mode_change(user, channel, {action, mode}, acc)
      end)
      |> then(fn {applied_changes, new_modes} ->
        {Enum.reverse(applied_changes), Enum.reverse(new_modes)}
      end)

    updated_channel = Channels.update(channel, %{modes: new_modes})

    {updated_channel, applied_changes}
  end

  @spec apply_mode_change(User.t(), Channel.t(), mode_change(), {[mode_change()], [mode()]}) ::
          {[mode_change()], [mode()]}
  defp apply_mode_change(user, channel, {:add, mode} = mode_change, {applied_changes, new_modes}) do
    mode_flag = extract_mode_flag(mode)

    cond do
      mode_flag in @modes_requiring_irc_operator ->
        apply_irc_operator_mode(user, mode_change, channel.name, applied_changes, new_modes)

      mode_flag in @modes_for_user_channel ->
        apply_user_channel_mode(user, mode_change, channel.name, applied_changes, new_modes)

      mode_flag in @modes_for_channel_ban ->
        apply_channel_ban_mode(user, mode_change, channel.name_key, applied_changes, new_modes)

      should_ignore_invalid_mode?(mode_flag, mode) ->
        handle_invalid_mode(user, mode_flag, mode, applied_changes, new_modes)

      mode_flag in @modes_with_value_to_replace ->
        apply_replaceable_mode(mode, mode_flag, applied_changes, new_modes)

      Enum.member?(new_modes, mode) ->
        {applied_changes, new_modes}

      true ->
        {[{:add, mode} | applied_changes], [mode | new_modes]}
    end
  end

  defp apply_mode_change(user, channel, {:remove, mode} = mode_change, {applied_changes, new_modes}) do
    mode_flag = extract_mode_flag(mode)

    cond do
      mode_flag in @modes_requiring_irc_operator ->
        apply_irc_operator_mode(user, mode_change, channel.name, applied_changes, new_modes)

      mode_flag in @modes_for_user_channel ->
        apply_user_channel_mode(user, mode_change, channel.name, applied_changes, new_modes)

      mode_flag in @modes_for_channel_ban ->
        apply_channel_ban_mode(user, mode_change, channel.name_key, applied_changes, new_modes)

      mode_flag in @modes_without_value_to_remove ->
        apply_valueless_mode_removal(mode, mode_flag, applied_changes, new_modes)

      Enum.member?(new_modes, mode) ->
        {[{:remove, mode} | applied_changes], List.delete(new_modes, mode)}

      true ->
        {applied_changes, new_modes}
    end
  end

  @spec extract_mode_flag(mode()) :: String.t()
  defp extract_mode_flag({mode, _val}), do: mode
  defp extract_mode_flag(mode), do: mode

  @spec apply_user_channel_mode(User.t(), mode_change(), String.t(), [mode_change()], [mode()]) ::
          {[mode_change()], [mode()]}
  defp apply_user_channel_mode(user, mode_change, channel_name, applied_changes, new_modes) do
    user_channel_mode_applied?(user, mode_change, channel_name)
    |> update_mode_changes(mode_change, applied_changes, new_modes)
  end

  @spec apply_channel_ban_mode(User.t(), mode_change(), String.t(), [mode_change()], [mode()]) ::
          {[mode_change()], [mode()]}
  defp apply_channel_ban_mode(user, mode_change, channel_name_key, applied_changes, new_modes) do
    updated_mode_change = normalize_mode_change_for_channel_ban(mode_change)

    channel_ban_mode_applied?(user, updated_mode_change, channel_name_key)
    |> update_mode_changes(updated_mode_change, applied_changes, new_modes)
  end

  @spec should_ignore_invalid_mode?(String.t(), mode()) :: boolean()
  defp should_ignore_invalid_mode?(mode_flag, mode) do
    (mode_flag in @modes_with_value_as_integer and not valid_integer_mode_value?(mode)) or
      (mode_flag == "j" and not valid_join_throttle_format?(mode))
  end

  @spec handle_invalid_mode(User.t(), String.t(), mode(), [mode_change()], [mode()]) ::
          {[mode_change()], [mode()]}
  defp handle_invalid_mode(user, mode_flag, mode, applied_changes, new_modes) do
    if mode_flag == "j" and not valid_join_throttle_format?(mode) do
      send_invalid_join_throttle_format_error(user)
    end

    {applied_changes, new_modes}
  end

  @spec apply_replaceable_mode(mode(), String.t(), [mode_change()], [mode()]) ::
          {[mode_change()], [mode()]}
  defp apply_replaceable_mode(mode, mode_flag, applied_changes, new_modes) do
    handled_new_modes = Enum.reject(new_modes, &match?({^mode_flag, _}, &1))
    {[{:add, mode} | applied_changes], [mode | handled_new_modes]}
  end

  @spec apply_valueless_mode_removal(mode(), String.t(), [mode_change()], [mode()]) ::
          {[mode_change()], [mode()]}
  defp apply_valueless_mode_removal(mode, mode_flag, applied_changes, new_modes) do
    handled_new_modes = Enum.reject(new_modes, &match?({^mode_flag, _}, &1))
    {[{:remove, mode} | applied_changes], handled_new_modes}
  end

  @spec apply_irc_operator_mode(User.t(), mode_change(), String.t(), [mode_change()], [mode()]) ::
          {[mode_change()], [mode()]}
  defp apply_irc_operator_mode(user, {:add, mode} = mode_change, _channel_name, applied_changes, new_modes) do
    if irc_operator?(user) do
      # ignore if the mode is already set
      if Enum.member?(new_modes, mode) do
        {applied_changes, new_modes}
      else
        {[mode_change | applied_changes], [mode | new_modes]}
      end
    else
      %Message{
        command: :err_noprivileges,
        params: [user.nick],
        trailing: "Permission Denied- You're not an IRC operator"
      }
      |> Dispatcher.broadcast(:server, user)

      {applied_changes, new_modes}
    end
  end

  defp apply_irc_operator_mode(user, {:remove, mode} = mode_change, _channel_name, applied_changes, new_modes) do
    if irc_operator?(user) do
      # ignore if the mode is not set
      if Enum.member?(new_modes, mode) do
        {[mode_change | applied_changes], List.delete(new_modes, mode)}
      else
        {applied_changes, new_modes}
      end
    else
      %Message{
        command: :err_noprivileges,
        params: [user.nick],
        trailing: "Permission Denied- You're not an IRC operator"
      }
      |> Dispatcher.broadcast(:server, user)

      {applied_changes, new_modes}
    end
  end

  @spec user_channel_mode_applied?(User.t(), mode_change(), String.t()) :: boolean()
  defp user_channel_mode_applied?(user, {_action, {_mode_flag, target_nick}} = mode_change, channel_name) do
    with {:ok, target_user} <- Users.get_by_nick(target_nick),
         {:ok, target_user_channel} <- UserChannels.get_by_user_pid_and_channel_name(target_user.pid, channel_name) do
      user_channel_mode_changed?(mode_change, target_user_channel)
    else
      {:error, :user_channel_not_found} ->
        %Message{
          command: :err_usernotinchannel,
          params: [user.nick, channel_name, target_nick],
          trailing: "They aren't on that channel"
        }
        |> Dispatcher.broadcast(:server, user)

        false

      {:error, :user_not_found} ->
        %Message{command: :err_nosuchnick, params: [user.nick, channel_name, target_nick], trailing: "No such nick"}
        |> Dispatcher.broadcast(:server, user)

        false
    end
  end

  @spec user_channel_mode_changed?(mode_change(), UserChannel.t()) :: boolean()
  defp user_channel_mode_changed?({:add, {mode_flag, _mode_value}}, user_channel) do
    if not Enum.member?(user_channel.modes, mode_flag) do
      UserChannels.update(user_channel, %{modes: [mode_flag | user_channel.modes]})
    end

    true
  end

  defp user_channel_mode_changed?({:remove, {mode_flag, _mode_value}}, user_channel) do
    if Enum.member?(user_channel.modes, mode_flag) do
      UserChannels.update(user_channel, %{modes: List.delete(user_channel.modes, mode_flag)})
      true
    else
      false
    end
  end

  @spec channel_ban_mode_applied?(User.t(), mode_change(), String.t()) :: boolean()
  defp channel_ban_mode_applied?(user, {_action, {_mode_flag, mode_value}} = mode_change, channel_name_key) do
    channel_ban =
      ChannelBans.get_by_channel_name_key_and_mask(channel_name_key, mode_value)
      |> case do
        {:ok, channel_ban} -> channel_ban
        {:error, :channel_ban_not_found} -> nil
      end

    channel_ban_mode_changed?(user, mode_change, channel_ban, channel_name_key)
  end

  @spec channel_ban_mode_changed?(User.t(), mode_change(), ChannelBan.t(), String.t()) :: boolean()
  defp channel_ban_mode_changed?(user, {:add, {_mode_flag, mode_value}}, nil, channel_name_key) do
    ChannelBans.create(%{channel_name_key: channel_name_key, mask: mode_value, setter: user_mask(user)})
    true
  end

  defp channel_ban_mode_changed?(_user, {:add, _mode}, _channel_ban, _channel_name_key), do: false
  defp channel_ban_mode_changed?(_user, {:remove, _mode}, nil, _channel_name_key), do: false

  defp channel_ban_mode_changed?(_user, {:remove, _mode}, channel_ban, _channel_name_key) do
    ChannelBans.delete(channel_ban)
    true
  end

  @spec update_mode_changes(boolean(), mode_change(), [mode_change()], [mode()]) :: {[mode_change()], [mode()]}
  defp update_mode_changes(true, mode_change, applied_changes, new_modes) do
    {[mode_change | applied_changes], new_modes}
  end

  defp update_mode_changes(false, _mode_change, applied_changes, new_modes), do: {applied_changes, new_modes}

  @spec normalize_mode_change_for_channel_ban(mode_change()) :: mode_change()
  defp normalize_mode_change_for_channel_ban({action, {mode_flag, mode_value}}) do
    {action, {mode_flag, normalize_mask(mode_value)}}
  end

  @spec valid_integer_mode_value?(mode()) :: boolean()
  defp valid_integer_mode_value?({_mode_flag, mode_value}) do
    case Integer.parse(mode_value) do
      {_value, ""} -> true
      _ -> false
    end
  end

  @spec valid_join_throttle_format?(mode()) :: boolean()
  defp valid_join_throttle_format?({_mode_flag, mode_value}) do
    case Regex.match?(~r/^\d+:\d+$/, mode_value) do
      true ->
        [joins_str, seconds_str] = String.split(mode_value, ":")

        case {Integer.parse(joins_str), Integer.parse(seconds_str)} do
          {{joins, ""}, {seconds, ""}} when joins > 0 and seconds > 0 -> true
          _ -> false
        end

      false ->
        false
    end
  end

  @spec send_invalid_join_throttle_format_error(User.t()) :: :ok
  defp send_invalid_join_throttle_format_error(user) do
    %Message{
      command: :err_unknownmode,
      params: [user.nick, "j"],
      trailing: "Invalid join throttle format. Expected <joins>:<seconds>"
    }
    |> Dispatcher.broadcast(:server, user)
  end
end
