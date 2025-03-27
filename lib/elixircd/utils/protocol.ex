defmodule ElixIRCd.Utils.Protocol do
  @moduledoc """
  Module for utility functions related to the IRC protocol.
  """

  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @doc """
  Determines if a target is a channel name.
  """
  @spec channel_name?(String.t()) :: boolean()
  def channel_name?(target), do: String.starts_with?(target, "#")

  @doc """
  Checks if a user is an IRC operator.
  """
  @spec irc_operator?(User.t()) :: boolean()
  def irc_operator?(user), do: "o" in user.modes

  @doc """
  Checks if a user is a channel operator.
  """
  @spec channel_operator?(UserChannel.t()) :: boolean()
  def channel_operator?(user_channel), do: "o" in user_channel.modes

  @doc """
  Checks if a user is a channel voice.
  """
  @spec channel_voice?(UserChannel.t()) :: boolean()
  def channel_voice?(user_channel), do: "v" in user_channel.modes

  @doc """
  Determines if a user mask matches a user.
  """
  @spec match_user_mask?(User.t(), String.t()) :: boolean()
  def match_user_mask?(user, mask) do
    mask
    |> String.replace(".", "\\.")
    |> String.replace("@", "\\@")
    |> String.replace("!", "\\!")
    |> String.replace("*", ".*")
    |> Regex.compile!()
    |> Regex.match?(user_mask(user))
  end

  @doc """
  Gets the user's reply to a message.
  """
  @spec user_reply(User.t()) :: String.t()
  def user_reply(%{registered: false}), do: "*"
  def user_reply(%{nick: nick}), do: nick

  @doc """
  Gets the user mask from a user.
  """
  @spec user_mask(User.t()) :: String.t()
  def user_mask(%{registered: true} = user)
      when user.nick != nil and user.ident != nil and user.hostname != nil do
    "#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname}"
  end

  def user_mask(%{registered: false}), do: "*"

  @doc """
  Parses a comma-separated list of targets into a list of channels or users.
  """
  @spec parse_targets(String.t()) :: {:channels, [String.t()]} | {:users, [String.t()]} | {:error, String.t()}
  def parse_targets(targets) do
    list_targets =
      targets
      |> String.split(",")

    cond do
      Enum.all?(list_targets, &channel_name?/1) ->
        {:channels, list_targets}

      Enum.all?(list_targets, fn target -> !channel_name?(target) end) ->
        {:users, list_targets}

      true ->
        {:error, "Invalid list of targets"}
    end
  end

  @doc """
  Normalizes a mask to the *!*@* IRC format.
  """
  @spec normalize_mask(String.t()) :: String.t()
  def normalize_mask(mask) do
    {nick_user, host} =
      case String.split(mask, "@", parts: 2) do
        [nick_user, host] -> {nick_user, host}
        [nick_user] -> {nick_user, "*"}
      end

    {nick, user} =
      case String.split(nick_user, "!", parts: 2) do
        [nick, user] ->
          {nick, user}

        [nick_or_user] ->
          if String.contains?(mask, "@") do
            {"*", nick_or_user}
          else
            {nick_or_user, "*"}
          end
      end

    "#{empty_mask_part_to_wildcard(nick)}!#{empty_mask_part_to_wildcard(user)}@#{empty_mask_part_to_wildcard(host)}"
  end

  @spec empty_mask_part_to_wildcard(String.t()) :: String.t()
  defp empty_mask_part_to_wildcard(""), do: "*"
  defp empty_mask_part_to_wildcard(mask), do: mask
end
