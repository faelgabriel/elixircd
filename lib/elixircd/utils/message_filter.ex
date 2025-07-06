defmodule ElixIRCd.Utils.MessageFilter do
  @moduledoc """
  Utility functions for filtering messages, including silence checking.
  """

  import ElixIRCd.Utils.Protocol, only: [match_user_mask?: 2]

  alias ElixIRCd.Repositories.UserSilences
  alias ElixIRCd.Tables.User

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
end
