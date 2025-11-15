defmodule ElixIRCd.Utils.MessageFilter do
  @moduledoc """
  Utility functions for filtering messages and broadcast recipients.
  """

  import ElixIRCd.Utils.Protocol, only: [match_user_mask?: 2, channel_operator?: 1, channel_voice?: 1]

  alias ElixIRCd.Repositories.UserSilences
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @doc """
  Check if a message should be silenced for a user.
  Returns true if the message should be dropped.
  """
  @spec should_silence_message?(User.t(), User.t()) :: boolean()
  def should_silence_message?(user, source_user) do
    silence_entries = UserSilences.get_by_user_pid(user.pid)

    Enum.any?(silence_entries, fn entry ->
      match_user_mask?(source_user, entry.mask)
    end)
  end

  @doc """
  Filters users based on auditorium mode (+u).
  Returns the list of user_channels that should be included in the broadcast.
  """
  @spec filter_auditorium_users([UserChannel.t()], UserChannel.t() | nil, [String.t()]) :: [UserChannel.t()]
  def filter_auditorium_users(user_channels, actor_user_channel, channel_modes) do
    cond do
      "u" not in channel_modes ->
        user_channels

      actor_user_channel && (channel_operator?(actor_user_channel) or channel_voice?(actor_user_channel)) ->
        user_channels

      true ->
        Enum.filter(user_channels, fn uc -> channel_operator?(uc) or channel_voice?(uc) end)
    end
  end

  @doc """
  Checks if a user can speak in a channel that has registered-only mode (+M).
  Returns :ok if the user can speak, or {:error, :registered_only_speak} otherwise.
  """
  @spec check_registered_only_speak(Channel.t(), User.t(), UserChannel.t() | nil) ::
          :ok | {:error, :registered_only_speak}
  def check_registered_only_speak(channel, user, user_channel) do
    cond do
      "M" not in channel.modes -> :ok
      "r" in user.modes -> :ok
      is_nil(user_channel) -> {:error, :registered_only_speak}
      channel_operator?(user_channel) or channel_voice?(user_channel) -> :ok
      true -> {:error, :registered_only_speak}
    end
  end
end
