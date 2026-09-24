defmodule ElixIRCd.Utils.MessageFilter do
  @moduledoc """
  Utility functions for filtering messages and broadcast recipients.
  """

  import ElixIRCd.Utils.Protocol,
    only: [match_mute_mask?: 2, match_user_mask?: 2, channel_operator?: 1, channel_voice?: 1]

  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.UserSilences
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.MessageText

  @doc "Whether the recipient's +T mode blocks a private CTCP, excluding ACTION."
  @spec private_ctcp_blocked?(User.t(), String.t()) :: boolean()
  def private_ctcp_blocked?(recipient, message_text) do
    :T in recipient.modes and MessageText.ctcp_message?(message_text) and
      not MessageText.ctcp_action?(message_text)
  end

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
      :u not in channel_modes ->
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
      :M not in channel.modes -> :ok
      :r in user.modes -> :ok
      is_nil(user_channel) -> {:error, :registered_only_speak}
      channel_operator?(user_channel) or channel_voice?(user_channel) -> :ok
      true -> {:error, :registered_only_speak}
    end
  end

  @doc """
  Checks channel mute extbans. Channel operators and voiced members bypass a
  mute, as do matching mute exceptions.
  """
  @spec check_channel_mute(Channel.t(), User.t(), UserChannel.t() | nil) ::
          :ok | {:error, :user_muted}
  def check_channel_mute(channel, user, %UserChannel{} = user_channel) do
    if channel_operator?(user_channel) or channel_voice?(user_channel) do
      :ok
    else
      check_channel_mute(channel, user, nil)
    end
  end

  def check_channel_mute(channel, user, _user_channel) do
    muted? =
      channel.name_key
      |> ChannelBans.get_by_channel_name_key()
      |> Enum.any?(&match_mute_mask?(user, &1.mask))

    excepted? =
      channel.name_key
      |> ChannelExcepts.get_by_channel_name_key()
      |> Enum.any?(&match_mute_mask?(user, &1.mask))

    if muted? and not excepted?, do: {:error, :user_muted}, else: :ok
  end

  @doc "Routes unprivileged messages in +U channels only to channel operators."
  @spec filter_op_moderated_users([UserChannel.t()], UserChannel.t() | nil, [term()]) :: [UserChannel.t()]
  def filter_op_moderated_users(user_channels, sender_membership, channel_modes) do
    privileged? =
      sender_membership &&
        (channel_operator?(sender_membership) or channel_voice?(sender_membership))

    if :U in channel_modes and not privileged? do
      Enum.filter(user_channels, &channel_operator?/1)
    else
      user_channels
    end
  end
end
