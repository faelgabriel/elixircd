defmodule ElixIRCd.Message do
  @moduledoc """
  Represents a structured IRC message format for both incoming and outgoing messages.

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
  @enforce_keys [:command, :params]

  @doc """
  The `source` denotes the origin of the message. It's typically the server name or a user's nick!user@host.
  If present, it starts with a colon `:` and ends before the first space.
  For incoming messages, the source is always nil.

  ## Examples (Outgoing)
  - ":irc.example.com" for messages from the server.
  - ":nick!user@host" for messages from a user.

  --------------------------------------------

  The `command` is either a standard IRC command (e.g., PRIVMSG, NOTICE, JOIN) or a three-digit numeric code representing a server response.

  ## Examples (Incoming)
  - "PRIVMSG" for private messages.
  - "NOTICE" for notice messages.

  ## Examples (Outgoing)
  - "001" as a welcome response code from the server.

  --------------------------------------------

  The `params` are a list of parameters for the command. This list does not include the trailing `body` part of the message.

  ## Examples (Incoming)
  - ["#channel", "Hello there!"] for a PRIVMSG command.
  - ["Nick"] for a NICK command when changing a nickname.

  ## Examples (Outgoing)
  - ["*"] for when a user has not registered.

  --------------------------------------------

  The `body` is the trailing part of the IRC message, which is optional and typically used for specifying the content of messages.

  If present, it starts with a colon `:` and continues to the end of the message.

  ## Examples (Incoming)
  - "Hello there!" as the content of a PRIVMSG.
  - "User has quit" as the content of a QUIT message.

  ## Examples (Outgoing)
  - "Welcome to the IRC server!" as the content of a welcome message.
  """
  defstruct source: nil, command: nil, params: [], body: nil

  @doc """
  Creates a new Message struct.
  """
  @spec new(%{
          optional(:source) => :server | String.t() | nil,
          :command => atom() | String.t(),
          :params => [String.t()],
          optional(:body) => String.t() | nil
        }) :: __MODULE__.t()
  def new(%{source: :server} = args) do
    args
    |> Map.put(:source, Application.get_env(:elixircd, :server_hostname))
    |> new()
  end

  def new(%{command: command} = args) when is_atom(command) do
    args
    |> Map.put(:command, numeric_reply(command))
    |> new()
  end

  def new(args) do
    %__MODULE__{
      source: args[:source],
      command: args[:command],
      params: args[:params],
      body: args[:body]
    }
  end

  @doc """
  Parses a raw IRC message string into an Message struct.

  ## Examples
  - For a message ":irc.example.com NOTICE user :Server restarting",
  - the function parses it into `%Message{source: "irc.example.com", command: "NOTICE", params: ["user"], body: "Server restarting"}`

  - For a message "JOIN #channel",
  - the function parses it into `%Message{source: nil, command: "JOIN", params: ["#channel"], body: nil}`

  - For a message ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user",
  - the function parses it into `%Message{source: "Freenode.net", command: "001", params: ["user"], body: "Welcome to the freenode Internet Relay Chat Network user"}`
  """
  @spec parse(String.t()) :: {:ok, __MODULE__.t()} | {:error, String.t()}
  def parse(message) do
    {source, message} = extract_source(message)

    parse_command_and_params(message)
    |> case do
      {command, params, body} -> {:ok, %__MODULE__{source: source, command: command, params: params, body: body}}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Parses the Message struct into a raw IRC message string.
  Raises an ArgumentError if the message cannot be unparsed.
  """
  @spec parse!(String.t()) :: __MODULE__.t()
  def parse!(message) do
    case parse(message) do
      {:ok, parsed} -> parsed
      {:error, error} -> raise ArgumentError, error
    end
  end

  @doc """
  Unparses the Message struct into a raw IRC message string.

  ## Examples
  - For `%Message{source: "irc.example.com", command: "NOTICE", params: ["user"], body: "Server restarting"}`,
  - the function unparses it into ":irc.example.com NOTICE user :Server restarting"

  - For `%Message{source: nil, command: "JOIN", params: ["#channel"], body: nil}`,
  - the function unparses it into "JOIN #channel"

  - For `%Message{source: "Freenode.net", command: "001", params: ["user"], body: "Welcome to the freenode Internet Relay Chat Network user"}`,
  - the function unparses it into ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"
  """
  @spec unparse(__MODULE__.t()) :: {:ok, String.t()} | {:error, String.t()}
  def unparse(%__MODULE__{command: ""} = message),
    do: {:error, "Invalid IRC message format on unparsing command: #{inspect(message)}"}

  def unparse(%__MODULE__{source: nil, command: command, params: params, body: body}) do
    base = [command | params]
    {:ok, unparse_message(base, body)}
  end

  def unparse(%__MODULE__{source: source, command: command, params: params, body: body}) do
    base = [":" <> source, command | params]
    {:ok, unparse_message(base, body)}
  end

  @doc """
  Unparses the Message struct into a raw IRC message string.
  Raises an ArgumentError if the message cannot be unparsed.
  """
  @spec unparse!(__MODULE__.t()) :: String.t()
  def unparse!(message) do
    case unparse(message) do
      {:ok, unparsed} -> unparsed
      {:error, error} -> raise ArgumentError, error
    end
  end

  # Extracts the source from the message if present.
  # It returns {source, message_without_source}.
  @spec extract_source(String.t()) :: {String.t() | nil, String.t()}
  defp extract_source(":" <> message) do
    [source | rest] = String.split(message, " ", parts: 2)
    {String.trim_leading(source, ":"), Enum.join(rest, " ")}
  end

  defp extract_source(message), do: {nil, message}

  # Parses the command and parameters from the message.
  # It returns {command, params, body} or {:error, error}.
  @spec parse_command_and_params(String.t()) :: {String.t(), [String.t()], String.t() | nil} | {:error, String.t()}
  defp parse_command_and_params(message) do
    parts = String.split(message, " ", trim: true)

    case parts do
      [command | params_and_body] ->
        {params, body} = extract_body(params_and_body)
        {String.upcase(command), params, body}

      [] ->
        {:error, "Invalid IRC message format on parsing command and params: #{inspect(message)}"}
    end
  end

  # Extracts the body from the parameters if present.
  @spec extract_body([String.t()]) :: {[String.t()], String.t() | nil}
  defp extract_body(parts) do
    # Find the index of the part where the body begins (first part containing a ':')
    body_index = Enum.find_index(parts, &String.contains?(&1, ":"))

    case body_index do
      nil ->
        # No body part; all parts are parameters
        {parts, nil}

      index ->
        # Extract parameters and body
        params = Enum.take(parts, index)
        body_parts = Enum.drop(parts, index)
        body = body_parts |> Enum.join(" ") |> String.trim_leading(":")
        {params, body}
    end
  end

  # Joins the base and body parts into a single message.
  @spec unparse_message([String.t()], String.t() | nil) :: String.t()
  defp unparse_message(base, nil), do: Enum.join(base, " ")
  defp unparse_message(base, body), do: Enum.join(base ++ [":" <> body], " ")

  # Numeric IRC response codes
  @spec numeric_reply(atom()) :: String.t()
  defp numeric_reply(:rpl_welcome), do: "001"
  defp numeric_reply(:rpl_yourhost), do: "002"
  defp numeric_reply(:rpl_created), do: "003"
  defp numeric_reply(:rpl_myinfo), do: "004"
  defp numeric_reply(:rpl_userhost), do: "302"
  defp numeric_reply(:rpl_whoisuser), do: "311"
  defp numeric_reply(:rpl_whoisserver), do: "312"
  defp numeric_reply(:rpl_whoisidle), do: "317"
  defp numeric_reply(:rpl_endofwhois), do: "318"
  defp numeric_reply(:rpl_whoischannels), do: "319"
  defp numeric_reply(:rpl_topic), do: "332"
  defp numeric_reply(:rpl_notregistered), do: "451"
  defp numeric_reply(:rpl_namreply), do: "353"
  defp numeric_reply(:rpl_endofnames), do: "366"
  defp numeric_reply(:rpl_endofmotd), do: "376"
  defp numeric_reply(:rpl_nouser), do: "401"
  defp numeric_reply(:rpl_cannotsendtochan), do: "404"
  defp numeric_reply(:rpl_cannotjoinchannel), do: "448"
  defp numeric_reply(:rpl_needmoreparams), do: "461"

  defp numeric_reply(:err_nosuchchannel), do: "403"
  defp numeric_reply(:err_unknowncommand), do: "421"
  defp numeric_reply(:err_erroneusnickname), do: "432"
  defp numeric_reply(:err_nicknameinuse), do: "433"
  defp numeric_reply(:err_notonchannel), do: "442"
  defp numeric_reply(:err_notregistered), do: "451"
end
