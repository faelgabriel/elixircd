defmodule ElixIRCd.Message do
  @moduledoc """
  Represents a structured IRC message format for both incoming and outgoing messages.

  An IRC message consists of the following parts:
  - `tags`: IRCv3 message tags as a map (optional)
  - `prefix`: The server or user source (optional)
  - `command`: The IRC command or numeric reply code
  - `params`: A list of parameters for the command (optional)
  - `trailing`: The trailing part of the message, typically the content of a PRIVMSG or NOTICE (optional)
  """

  @doc """
  The `tags` contain IRCv3 message tags as a map. Tags are key-value pairs that provide metadata about messages.
  If present, tags appear at the beginning of the message, prefixed with `@` and separated by semicolons.
  Tags without values are represented with `nil` as their value.

  ## Examples
  - %{"bot" => nil} for a message from a bot (tag without value)
  - %{"account" => "user123"} for a message with account tag
  - %{"msgid" => "abc123", "bot" => nil} for a message with multiple tags

  --------------------------------------------

  The `prefix` denotes the origin of the message. It's typically the server name or a user's nick!user@host.
  If present, it starts with a colon `:` and ends before the first space.
  For incoming messages, the prefix is always nil.

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

  The `params` are a list of parameters for the command. This list does not include the trailing part of the message.

  ## Examples (Incoming)
  - ["#channel", "Hello there!"] for a PRIVMSG command.
  - ["Nick"] for a NICK command when changing a nickname.

  ## Examples (Outgoing)
  - ["*"] for when a user has not registered.

  --------------------------------------------

  The `trailing` is the trailing part of the IRC message, which is optional and typically used for specifying the content of messages.

  If present, it starts with a colon `:` and continues to the end of the message.

  ## Examples (Incoming)
  - "Hello there!" as the content of a PRIVMSG.
  - "User has quit" as the content of a QUIT message.

  ## Examples (Outgoing)
  - "Welcome to the IRC server!" as the content of a welcome message.
  """
  @enforce_keys [:command, :params]
  defstruct tags: %{}, prefix: nil, command: nil, params: [], trailing: nil

  @type t :: %__MODULE__{
          tags: %{optional(String.t()) => String.t() | nil},
          prefix: String.t() | nil,
          command: String.t() | atom(),
          params: [String.t()],
          trailing: String.t() | nil
        }

  @doc """
  Parses a raw IRC message string into an Message struct.

  ## Examples
  - For a message ":irc.example.com NOTICE user :Server restarting",
  - the function parses it into `%Message{prefix: "irc.example.com", command: "NOTICE", params: ["user"], trailing: "Server restarting"}`

  - For a message "JOIN #channel",
  - the function parses it into `%Message{prefix: nil, command: "JOIN", params: ["#channel"], trailing: nil}`

  - For a message ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user",
  - the function parses it into `%Message{prefix: "Freenode.net", command: "001", params: ["user"], trailing: "Welcome to the freenode Internet Relay Chat Network user"}`
  """
  @spec parse(String.t()) :: {:ok, __MODULE__.t()} | {:error, String.t()}
  def parse(raw_message) do
    {tags, rest_after_tags} =
      raw_message
      |> String.trim_trailing()
      |> extract_tags()

    {prefix, rest_raw_message} = extract_prefix(rest_after_tags)

    parse_command_and_params(rest_raw_message)
    |> case do
      {command, params, trailing} ->
        {:ok, %__MODULE__{tags: tags, prefix: prefix, command: command, params: params, trailing: trailing}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Parses a raw IRC message string into an Message struct.

  Raises an ArgumentError if the message cannot be unparsed.
  """
  @spec parse!(String.t()) :: __MODULE__.t()
  def parse!(raw_message) do
    case parse(raw_message) do
      {:ok, parsed} -> parsed
      {:error, error} -> raise ArgumentError, error
    end
  end

  @doc """
  Unparses the Message struct into a raw IRC message string.

  ## Examples
  - For `%Message{prefix: "irc.example.com", command: "NOTICE", params: ["user"], trailing: "Server restarting"}`,
  - the function unparses it into ":irc.example.com NOTICE user :Server restarting"

  - For `%Message{prefix: nil, command: "JOIN", params: ["#channel"], trailing: nil}`,
  - the function unparses it into "JOIN #channel"

  - For `%Message{prefix: "Freenode.net", command: "001", params: ["user"], trailing: "Welcome to the freenode Internet Relay Chat Network user"}`,
  - the function unparses it into ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"
  """
  @spec unparse(__MODULE__.t()) :: {:ok, String.t()} | {:error, String.t()}
  def unparse(%__MODULE__{command: command} = message) when is_atom(command) do
    %{message | command: numeric_reply(command)}
    |> unparse()
  end

  def unparse(%__MODULE__{command: ""} = message),
    do: {:error, "Invalid IRC message format on unparsing command: #{inspect(message)}"}

  def unparse(%__MODULE__{tags: tags, prefix: nil, command: command, params: params, trailing: trailing}) do
    base = [command | params]
    message_str = unparse_message(base, trailing)
    {:ok, prepend_tags(tags, message_str) <> "\r\n"}
  end

  def unparse(%__MODULE__{tags: tags, prefix: prefix, command: command, params: params, trailing: trailing}) do
    base = [":" <> prefix, command | params]
    message_str = unparse_message(base, trailing)
    {:ok, prepend_tags(tags, message_str) <> "\r\n"}
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

  # Extracts IRCv3 message tags from the beginning of the message if present.
  # Tags are in the format: @tag1=value1;tag2=value2;tag3
  # Returns {tags_map, message_without_tags}
  @spec extract_tags(String.t()) :: {%{optional(String.t()) => String.t() | nil}, String.t()}
  defp extract_tags("@" <> message) do
    [tags_string | rest] = String.split(message, " ", parts: 2)
    tags = parse_tags(tags_string)
    {tags, Enum.join(rest, " ")}
  end

  defp extract_tags(message), do: {%{}, message}

  # Parses a tags string into a map.
  # Format: tag1=value1;tag2=value2;tag3
  @spec parse_tags(String.t()) :: %{optional(String.t()) => String.t() | nil}
  defp parse_tags(tags_string) do
    tags_string
    |> String.split(";")
    |> Enum.map(&parse_single_tag/1)
    |> Enum.into(%{})
  end

  # Parses a single tag into {key, value} tuple.
  # Tags without values become {key, nil}
  @spec parse_single_tag(String.t()) :: {String.t(), String.t() | nil}
  defp parse_single_tag(tag) do
    case String.split(tag, "=", parts: 2) do
      [key, value] -> {key, unescape_tag_value(value)}
      [key] -> {key, nil}
    end
  end

  # Unescapes IRCv3 tag values according to the spec.
  # \: -> ; \s -> space \\ -> \ \r -> CR \n -> LF
  @spec unescape_tag_value(String.t()) :: String.t()
  defp unescape_tag_value(value) do
    value
    |> String.replace("\\:", ";")
    |> String.replace("\\s", " ")
    |> String.replace("\\r", "\r")
    |> String.replace("\\n", "\n")
    |> String.replace("\\\\", "\\")
  end

  # Prepends tags to a message string if tags are present.
  # Returns the message with tags prepended, or the original message if no tags.
  @spec prepend_tags(%{optional(String.t()) => String.t() | nil}, String.t()) :: String.t()
  defp prepend_tags(tags, message) when map_size(tags) == 0, do: message

  defp prepend_tags(tags, message) do
    tags_string = format_tags(tags)
    "@#{tags_string} #{message}"
  end

  # Formats tags map into IRCv3 tags string.
  # Format: tag1=value1;tag2=value2;tag3
  @spec format_tags(%{optional(String.t()) => String.t() | nil}) :: String.t()
  defp format_tags(tags) do
    Enum.map_join(tags, ";", &format_single_tag/1)
  end

  # Formats a single tag into "key=value" or "key" format.
  @spec format_single_tag({String.t(), String.t() | nil}) :: String.t()
  defp format_single_tag({key, nil}), do: key

  defp format_single_tag({key, value}) do
    "#{key}=#{escape_tag_value(value)}"
  end

  # Escapes IRCv3 tag values according to the spec.
  # ; -> \: space -> \s \ -> \\ CR -> \r LF -> \n
  @spec escape_tag_value(String.t()) :: String.t()
  defp escape_tag_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\:")
    |> String.replace(" ", "\\s")
    |> String.replace("\r", "\\r")
    |> String.replace("\n", "\\n")
  end

  # Extracts the prefix from the message if present.
  # It returns {prefix, message_without_prefix}.
  @spec extract_prefix(String.t()) :: {String.t() | nil, String.t()}
  defp extract_prefix(":" <> message) do
    [prefix | rest] = String.split(message, " ", parts: 2)
    {String.trim_leading(prefix, ":"), Enum.join(rest, " ")}
  end

  defp extract_prefix(message), do: {nil, message}

  # Parses the command and parameters from the message.
  # It returns {command, params, trailing} or {:error, error}.
  @spec parse_command_and_params(String.t()) :: {String.t(), [String.t()], String.t() | nil} | {:error, String.t()}
  defp parse_command_and_params(message) do
    parts = String.split(message, " ", trim: true)

    case parts do
      [command | params_and_trailing] ->
        {params, trailing} = extract_trailing(params_and_trailing)
        {String.upcase(command), params, trailing}

      [] ->
        {:error, "Invalid IRC message format on parsing command and params: #{inspect(message)}"}
    end
  end

  # Extracts the trailing from the parameters if present.
  @spec extract_trailing([String.t()]) :: {[String.t()], String.t() | nil}
  defp extract_trailing(parts) do
    # Find the index of the part where the trailing begins (first part starting with ':')
    trailing_index = Enum.find_index(parts, &String.starts_with?(&1, ":"))

    case trailing_index do
      nil ->
        # No trailing part; all parts are parameters
        {parts, nil}

      index ->
        # Extract parameters and trailing
        params = Enum.take(parts, index)
        trailing_parts = Enum.drop(parts, index)
        trailing = trailing_parts |> Enum.join(" ") |> String.trim_leading(":")
        {params, trailing}
    end
  end

  # Joins the base and trailing parts into a single message.
  @spec unparse_message([String.t()], String.t() | nil) :: String.t()
  defp unparse_message(base, nil), do: Enum.join(base, " ")
  defp unparse_message(base, trailing), do: Enum.join(base ++ [":" <> trailing], " ")

  # Numeric IRC reply codes
  @spec numeric_reply(atom()) :: String.t()
  defp numeric_reply(:rpl_welcome), do: "001"
  defp numeric_reply(:rpl_yourhost), do: "002"
  defp numeric_reply(:rpl_created), do: "003"
  defp numeric_reply(:rpl_myinfo), do: "004"
  defp numeric_reply(:rpl_isupport), do: "005"
  defp numeric_reply(:rpl_traceuser), do: "205"
  defp numeric_reply(:rpl_traceend), do: "262"
  defp numeric_reply(:rpl_stats), do: "210"
  defp numeric_reply(:rpl_endofstats), do: "219"
  defp numeric_reply(:rpl_umodeis), do: "221"
  defp numeric_reply(:rpl_statsuptime), do: "242"
  defp numeric_reply(:rpl_statsconn), do: "250"
  defp numeric_reply(:rpl_luserclient), do: "251"
  defp numeric_reply(:rpl_luserop), do: "252"
  defp numeric_reply(:rpl_luserunknown), do: "253"
  defp numeric_reply(:rpl_luserchannels), do: "254"
  defp numeric_reply(:rpl_luserme), do: "255"
  defp numeric_reply(:rpl_adminme), do: "256"
  defp numeric_reply(:rpl_adminloc1), do: "257"
  defp numeric_reply(:rpl_adminloc2), do: "258"
  defp numeric_reply(:rpl_adminemail), do: "259"
  defp numeric_reply(:rpl_localusers), do: "265"
  defp numeric_reply(:rpl_globalusers), do: "266"
  defp numeric_reply(:rpl_acceptlist), do: "281"
  defp numeric_reply(:rpl_acceptlistend), do: "282"
  defp numeric_reply(:rpl_accepted), do: "287"
  defp numeric_reply(:rpl_acceptremoved), do: "288"
  defp numeric_reply(:rpl_silence_list), do: "271"
  defp numeric_reply(:rpl_endofsilence), do: "272"
  defp numeric_reply(:rpl_away), do: "301"
  defp numeric_reply(:rpl_userhost), do: "302"
  defp numeric_reply(:rpl_ison), do: "303"
  defp numeric_reply(:rpl_unaway), do: "305"
  defp numeric_reply(:rpl_nowaway), do: "306"
  defp numeric_reply(:rpl_whoisregnick), do: "307"
  defp numeric_reply(:rpl_whoisuser), do: "311"
  defp numeric_reply(:rpl_whoisserver), do: "312"
  defp numeric_reply(:rpl_whoisoperator), do: "313"
  defp numeric_reply(:rpl_whowasuser), do: "314"
  defp numeric_reply(:rpl_endofwho), do: "315"
  defp numeric_reply(:rpl_whoisidle), do: "317"
  defp numeric_reply(:rpl_endofwhois), do: "318"
  defp numeric_reply(:rpl_whoischannels), do: "319"
  defp numeric_reply(:rpl_list), do: "322"
  defp numeric_reply(:rpl_listend), do: "323"
  defp numeric_reply(:rpl_whoisaccount), do: "330"
  defp numeric_reply(:rpl_notopic), do: "331"
  defp numeric_reply(:rpl_topic), do: "332"
  defp numeric_reply(:rpl_topicwhotime), do: "333"
  defp numeric_reply(:rpl_whoisbot), do: "335"
  defp numeric_reply(:rpl_whoisactually), do: "338"
  defp numeric_reply(:rpl_inviting), do: "341"
  defp numeric_reply(:rpl_invexlist), do: "346"
  defp numeric_reply(:rpl_endofinvexlist), do: "347"
  defp numeric_reply(:rpl_exceptlist), do: "348"
  defp numeric_reply(:rpl_endofexceptlist), do: "349"
  defp numeric_reply(:rpl_version), do: "351"
  defp numeric_reply(:rpl_whoreply), do: "352"
  defp numeric_reply(:rpl_namreply), do: "353"
  defp numeric_reply(:rpl_endofnames), do: "366"
  defp numeric_reply(:rpl_banlist), do: "367"
  defp numeric_reply(:rpl_endofbanlist), do: "368"
  defp numeric_reply(:rpl_endofwhowas), do: "369"
  defp numeric_reply(:rpl_info), do: "371"
  defp numeric_reply(:rpl_motd), do: "372"
  defp numeric_reply(:rpl_endofinfo), do: "374"
  defp numeric_reply(:rpl_motdstart), do: "375"
  defp numeric_reply(:rpl_endofmotd), do: "376"
  defp numeric_reply(:rpl_youreoper), do: "381"
  defp numeric_reply(:rpl_rehashing), do: "382"
  defp numeric_reply(:rpl_time), do: "391"
  defp numeric_reply(:rpl_umodegmsg), do: "716"
  # Error replies
  defp numeric_reply(:err_nosuchnick), do: "401"
  defp numeric_reply(:err_nosuchchannel), do: "403"
  defp numeric_reply(:err_cannotsendtochan), do: "404"
  defp numeric_reply(:err_toomanychannels), do: "405"
  defp numeric_reply(:err_wasnosuchnick), do: "406"
  defp numeric_reply(:err_inputtoolong), do: "417"
  defp numeric_reply(:err_unknowncommand), do: "421"
  defp numeric_reply(:err_nomotd), do: "422"
  defp numeric_reply(:err_erroneusnickname), do: "432"
  defp numeric_reply(:err_nicknameinuse), do: "433"
  defp numeric_reply(:err_usernotinchannel), do: "441"
  defp numeric_reply(:err_notonchannel), do: "442"
  defp numeric_reply(:err_useronchannel), do: "443"
  defp numeric_reply(:err_notregistered), do: "451"
  defp numeric_reply(:err_needreggednick), do: "477"
  defp numeric_reply(:err_secureonlychan), do: "489"
  defp numeric_reply(:err_acceptnot), do: "457"
  defp numeric_reply(:err_acceptexist), do: "458"
  defp numeric_reply(:err_needmoreparams), do: "461"
  defp numeric_reply(:err_alreadyregistered), do: "462"
  defp numeric_reply(:err_passwdmismatch), do: "464"
  defp numeric_reply(:err_channelisfull), do: "471"
  defp numeric_reply(:err_unknownmode), do: "472"
  defp numeric_reply(:err_inviteonlychan), do: "473"
  defp numeric_reply(:err_bannedfromchan), do: "474"
  defp numeric_reply(:err_badchannelkey), do: "475"
  defp numeric_reply(:err_badchanmask), do: "476"
  defp numeric_reply(:err_noprivileges), do: "481"
  defp numeric_reply(:err_chanoprivsneeded), do: "482"
  defp numeric_reply(:err_usersdontmatch), do: "502"
  defp numeric_reply(:err_silencelistfull), do: "511"
  defp numeric_reply(:err_ircoperonlychan), do: "520"
  defp numeric_reply(:err_delaymessageblocked), do: "937"
end
