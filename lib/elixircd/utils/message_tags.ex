defmodule ElixIRCd.Utils.MessageTags do
  @moduledoc """
  Utilities for managing IRCv3 message tags.
  """

  alias ElixIRCd.Message
  alias ElixIRCd.Tables.User

  @doc """
  Adds the "bot" tag to a message if the sender has the +B user mode.

  The bot tag MUST be sent without a value according to IRCv3 spec.
  The tag will be filtered later by the Dispatcher based on recipient capabilities.
  """
  @spec maybe_add_bot_tag(Message.t(), User.t()) :: Message.t()
  def maybe_add_bot_tag(message, %User{modes: modes} = _sender) do
    if "B" in modes do
      add_tag(message, "bot", nil)
    else
      message
    end
  end

  @doc """
  Adds a tag to a message.

  If the value is nil, the tag will be added without a value (as per IRCv3 spec).
  """
  @spec add_tag(Message.t(), String.t(), String.t() | nil) :: Message.t()
  def add_tag(%Message{tags: tags} = message, key, value) do
    %{message | tags: Map.put(tags, key, value)}
  end

  @doc """
  Removes a tag from a message.
  """
  @spec remove_tag(Message.t(), String.t()) :: Message.t()
  def remove_tag(%Message{tags: tags} = message, key) do
    %{message | tags: Map.delete(tags, key)}
  end

  @doc """
  Checks if a message has a specific tag.
  """
  @spec has_tag?(Message.t(), String.t()) :: boolean()
  def has_tag?(%Message{tags: tags}, key) do
    Map.has_key?(tags, key)
  end

  @doc """
  Gets the value of a tag from a message.
  Returns nil if the tag doesn't exist or has no value.
  """
  @spec get_tag(Message.t(), String.t()) :: String.t() | nil
  def get_tag(%Message{tags: tags}, key) do
    Map.get(tags, key)
  end

  @doc """
  Filters message tags based on recipient capabilities.

  Only sends tags to users who have requested the "MESSAGE-TAGS" capability.
  """
  @spec filter_tags_for_recipient(Message.t(), User.t()) :: Message.t()
  def filter_tags_for_recipient(message, %User{capabilities: caps} = _recipient) do
    if "MESSAGE-TAGS" in caps do
      message
    else
      %{message | tags: %{}}
    end
  end
end
