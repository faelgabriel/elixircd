defmodule ElixIRCd.Utils.MessageText do
  @moduledoc """
  Utility functions for inspecting IRC MessageText.
  """

  # IRC formatting control characters
  @formatting_chars [
    # Color
    "\x03",
    # Bold
    "\x02",
    # Underline
    "\x1F",
    # Reverse
    "\x16",
    # Italic
    "\x1D",
    # Strikethrough
    "\x1E",
    # Monospace
    "\x11",
    # Reset
    "\x0F"
  ]

  @doc """
  Checks if a message contains IRC formatting characters.
  """
  @spec contains_formatting?(String.t()) :: boolean()
  def contains_formatting?(message_text) do
    Enum.any?(@formatting_chars, fn char ->
      String.contains?(message_text, char)
    end)
  end

  @doc """
  Checks if a message is a CTCP message.
  """
  @spec ctcp_message?(String.t()) :: boolean()
  def ctcp_message?(message_text) do
    String.starts_with?(message_text, "\x01") and String.ends_with?(message_text, "\x01")
  end
end
