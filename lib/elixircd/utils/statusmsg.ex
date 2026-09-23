defmodule ElixIRCd.Utils.Statusmsg do
  @moduledoc """
  Helpers for ISUPPORT STATUSMSG channel targets.
  """

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, channel_operator?: 1, channel_voice?: 1]

  alias ElixIRCd.Tables.UserChannel

  @status_prefixes ["@", "+"]

  @doc "Returns the underlying channel and requested minimum status."
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse(<<prefix::binary-size(1), channel_name::binary>>) when prefix in @status_prefixes do
    if channel_name?(channel_name), do: {:ok, channel_name, prefix}, else: :error
  end

  def parse(_target), do: :error

  @doc "Returns whether a channel membership is eligible for a status target."
  @spec eligible?(UserChannel.t(), String.t()) :: boolean()
  def eligible?(user_channel, "@"), do: channel_operator?(user_channel)
  def eligible?(user_channel, "+"), do: channel_operator?(user_channel) or channel_voice?(user_channel)
end
