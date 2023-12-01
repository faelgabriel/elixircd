defmodule ElixIRCd.Message.Message do
  @moduledoc """
  Represents a structured format for IRC messages.

  An IRC message consists of the following parts:
  - `source`: The server or user source (optional)
  - `command`: The IRC command or numeric reply code
  - `params`: A list of parameters for the command (optional)
  - `body`: The trailing part of the message, typically the content of a PRIVMSG or NOTICE (optional)
  """

  @type t :: %__MODULE__{
          source: String.t() | nil,
          command: String.t(),
          params: [String.t()],
          body: String.t() | nil
        }

  @doc """
  The `source` denotes the origin of the message. It's typically the server name or a user's nick!user@host.
  If present, it starts with a colon `:` and ends before the first space.

  ## Examples
  - ":irc.example.com" for messages from the server.
  - ":Nick!~user@host.com" for messages from a user.

  --------------------------------------------

  The `command` is either a standard IRC command (e.g., PRIVMSG, NOTICE, JOIN) or a three-digit numeric code representing a server response.

  ## Examples
  - "PRIVMSG" for private messages.
  - "NOTICE" for notice messages.
  - "001" as a welcome response code from the server.

  --------------------------------------------

  The `params` are a list of parameters for the command. This list does not include the trailing `body` part of the message.

  ## Examples
  - ["#channel", "Hello there!"] for a PRIVMSG command.
  - ["Nick"] for a NICK command when changing a nickname.
  - ["*"] for when a user has not registered.

  --------------------------------------------

  The `body` is the trailing part of the IRC message, which is optional and typically used for specifying the content of messages.

  If present, it starts with a colon `:` and continues to the end of the message.

  ## Examples
  - "Hello there!" as the content of a PRIVMSG.
  - "User has quit" as the content of a QUIT message.
  """
  defstruct source: nil, command: nil, params: [], body: nil
end
