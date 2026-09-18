defmodule ElixIRCd.Utils.Chanserv.ModeLock do
  @moduledoc """
  Validates and reapplies ChanServ channel mode locks.

  A mode lock is stored in the same wire format used by MODE, for example
  `+nt` or `+kl 25 secret`. Membership and list modes are deliberately not
  accepted because they describe live users or masks rather than stable
  channel policy.
  """

  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User

  @unsupported_modes [:b, :e, :I, :o, :v]

  @type validation_error ::
          :empty_mode_lock
          | :invalid_mode
          | :listing_mode
          | :missing_mode_parameter
          | :unsupported_mode

  @doc "Validates and canonicalizes a MLOCK expression."
  @spec validate(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, validation_error()}
  def validate(mode_string, values) when is_binary(mode_string) and is_list(values) do
    if String.valid?(mode_string) do
      case ChannelModes.parse_mode_changes(mode_string, values) do
        {changes, []} -> validate_parsed_changes(changes)
        _ -> {:error, :invalid_mode}
      end
    else
      {:error, :invalid_mode}
    end
  end

  def validate(_mode_string, _values), do: {:error, :invalid_mode}

  @spec validate_parsed_changes([ChannelModes.mode_change()]) ::
          {:ok, String.t()} | {:error, validation_error()}
  defp validate_parsed_changes(changes) do
    {filtered_changes, listing_modes, missing_modes} = ChannelModes.filter_mode_changes(changes)

    cond do
      filtered_changes == [] and listing_modes == [] and missing_modes == [] ->
        {:error, :empty_mode_lock}

      missing_modes != [] ->
        {:error, :missing_mode_parameter}

      listing_modes != [] ->
        {:error, :listing_mode}

      Enum.any?(filtered_changes, &unsupported_mode_change?/1) ->
        {:error, :unsupported_mode}

      true ->
        {:ok, ChannelModes.display_mode_changes(filtered_changes)}
    end
  end

  @doc "Parses a persisted canonical mode lock. Invalid legacy data is ignored safely."
  @spec parse(String.t() | nil) :: {:ok, [ChannelModes.mode_change()]} | :error
  def parse(nil), do: :error
  def parse(""), do: :error

  def parse(mode_lock) when is_binary(mode_lock) do
    case String.split(mode_lock) do
      [mode_string | values] ->
        with {:ok, canonical} <- validate(mode_string, values),
             ^mode_lock <- canonical,
             {changes, []} <- ChannelModes.parse_mode_changes(mode_string, values),
             {filtered_changes, [], []} <- ChannelModes.filter_mode_changes(changes) do
          {:ok, filtered_changes}
        else
          _ -> :error
        end
    end
  end

  def parse(_mode_lock), do: :error

  @doc "Reconciles live channel modes with the registered channel's MLOCK."
  @spec reconcile(Channel.t(), RegisteredChannel.t(), User.t()) :: {Channel.t(), [ChannelModes.mode_change()]}
  def reconcile(channel, registered_channel, actor) do
    case parse(Map.get(registered_channel.settings, :mlock)) do
      {:ok, mode_changes} -> ChannelModes.apply_mode_changes(actor, channel, mode_changes)
      :error -> {channel, []}
    end
  end

  @doc "Reconciles and broadcasts the changes made by ChanServ."
  @spec reconcile_and_broadcast(Channel.t(), RegisteredChannel.t(), User.t()) ::
          {Channel.t(), [ChannelModes.mode_change()]}
  def reconcile_and_broadcast(channel, registered_channel, actor) do
    {updated_channel, applied_changes} = reconcile(channel, registered_channel, actor)
    broadcast(updated_channel, applied_changes)
    {updated_channel, applied_changes}
  end

  @doc "Broadcasts a mode-lock correction to everyone currently in the channel."
  @spec broadcast(Channel.t(), [ChannelModes.mode_change()]) :: :ok
  def broadcast(_channel, []), do: :ok

  def broadcast(channel, applied_changes) do
    user_pids = UserChannels.get_by_channel_name(channel.name) |> Enum.map(& &1.user_pid)
    users = Users.get_by_pids(user_pids)

    %ElixIRCd.Message{
      command: "MODE",
      params: [channel.name, ChannelModes.display_mode_changes(applied_changes)]
    }
    |> Dispatcher.broadcast(:chanserv, users)
  end

  @spec unsupported_mode_change?(ChannelModes.mode_change()) :: boolean()
  defp unsupported_mode_change?({_action, {mode, _value}}), do: mode in @unsupported_modes
  defp unsupported_mode_change?({_action, mode}), do: mode in @unsupported_modes
end
