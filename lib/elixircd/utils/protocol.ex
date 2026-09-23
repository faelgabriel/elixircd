defmodule ElixIRCd.Utils.Protocol do
  @moduledoc """
  Module for utility functions related to the IRC protocol.
  """

  alias ElixIRCd.Message
  alias ElixIRCd.Service
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping

  @max_irc_message_bytes 512

  @type word_choice :: String.t() | {String.t(), String.t()}

  @doc """
  Determines if a target is a channel name.
  """
  @spec channel_name?(String.t()) :: boolean()
  def channel_name?(target) when is_binary(target) and byte_size(target) > 0 do
    chantypes = Application.fetch_env!(:elixircd, :channel)[:channel_prefixes]
    String.first(target) in chantypes
  end

  def channel_name?(_target), do: false

  @doc """
  Determines if a target is a service name.
  """
  @spec service_name?(String.t()) :: boolean()
  def service_name?(target), do: Service.service_implemented?(target)

  @doc """
  Checks if a user is an IRC operator.
  """
  @spec irc_operator?(User.t()) :: boolean()
  def irc_operator?(user), do: :o in user.modes

  @doc """
  Checks whether a viewer may see a user's IRC operator status, respecting +H.
  """
  @spec irc_operator_visible?(User.t(), User.t()) :: boolean()
  def irc_operator_visible?(target, viewer) do
    irc_operator?(target) and (:H not in target.modes or User.same_identity?(target, viewer) or irc_operator?(viewer))
  end

  @doc """
  Checks if a user is a channel operator.
  """
  @spec channel_operator?(UserChannel.t()) :: boolean()
  def channel_operator?(user_channel), do: :o in user_channel.modes

  @doc """
  Checks if a user is a channel voice.
  """
  @spec channel_voice?(UserChannel.t()) :: boolean()
  def channel_voice?(user_channel), do: :v in user_channel.modes

  @doc """
  Determines if a user mask matches a user.
  """
  @spec match_user_mask?(User.t(), String.t()) :: boolean()
  def match_user_mask?(user, "$a:" <> account_pattern) do
    is_binary(user.identified_as) and match_glob?(user.identified_as, account_pattern)
  end

  def match_user_mask?(user, "$r:" <> realname_pattern) do
    is_binary(user.realname) and match_glob?(user.realname, realname_pattern)
  end

  def match_user_mask?(_user, "$m:" <> _mask), do: false
  def match_user_mask?(%{registered: false}, mask), do: match_mask(mask, "*", nil)

  def match_user_mask?(user, mask) do
    {nick, ident, host} = mask |> normalize_mask() |> parse_mask_parts()
    {user_nick, user_ident, user_host} = user |> user_mask() |> parse_mask_parts()

    match_mask(CaseMapping.normalize(nick), CaseMapping.normalize(user_nick), nil) and
      match_mask(ascii_lower(ident), ascii_lower(user_ident), nil) and
      match_mask(ascii_lower(host), ascii_lower(user_host), nil)
  end

  @doc "Matches an IRC glob using the configured IRC case mapping."
  @spec match_glob?(String.t(), String.t()) :: boolean()
  def match_glob?(value, pattern) when is_binary(value) and is_binary(pattern) do
    regex_source =
      pattern
      |> CaseMapping.normalize()
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(Regex.compile!("^#{regex_source}$", "u"), CaseMapping.normalize(value))
  end

  def match_glob?(_value, _pattern), do: false

  @doc "Returns whether a mute extban matches a user."
  @spec match_mute_mask?(User.t(), String.t()) :: boolean()
  def match_mute_mask?(user, "$m:" <> mask), do: match_user_mask?(user, mask)
  def match_mute_mask?(_user, _mask), do: false

  @spec message_fits?(Message.t(), pos_integer()) :: boolean()
  defp message_fits?(%Message{} = message, max_bytes) do
    message
    |> Map.put(:tags, %{})
    |> Message.unparse_unbounded!()
    |> byte_size()
    |> Kernel.<=(max_bytes)
  end

  @doc "Splits a word-based trailing response without splitting a protocol token."
  @spec chunk_message_words(Message.t(), [word_choice()], pos_integer()) :: [Message.t()]
  def chunk_message_words(%Message{} = message, words, max_bytes \\ @max_irc_message_bytes)
      when is_list(words) and is_integer(max_bytes) and max_bytes > 0 do
    {chunks, current} =
      Enum.reduce(words, {[], []}, fn word_choice, {chunks, current} ->
        choices = word_choices(word_choice)

        case choose_word(message, current, choices, max_bytes) do
          {:current, word} ->
            {chunks, current ++ [word]}

          {:new, word} ->
            {[%{message | trailing: Enum.join(current, " ")} | chunks], [word]}

          :error ->
            raise ArgumentError, "IRC response contains a protocol token that cannot fit on one line"
        end
      end)

    chunks = if current == [], do: chunks, else: [%{message | trailing: Enum.join(current, " ")} | chunks]
    Enum.reverse(chunks)
  end

  @doc "Splits arbitrary UTF-8 trailing text on grapheme boundaries to fit IRC wire limits."
  @spec chunk_message_text(Message.t(), String.t(), pos_integer()) :: [Message.t()]
  def chunk_message_text(%Message{} = message, text, max_bytes \\ @max_irc_message_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes > 0 do
    {chunks, current} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], ""}, &append_text_grapheme(message, max_bytes, &1, &2))

    chunks = if current == "" and chunks != [], do: chunks, else: [%{message | trailing: current} | chunks]
    Enum.reverse(chunks)
  end

  @spec append_text_grapheme(Message.t(), pos_integer(), String.t(), {[Message.t()], String.t()}) ::
          {[Message.t()], String.t()}
  defp append_text_grapheme(message, max_bytes, grapheme, {chunks, current}) do
    candidate = current <> grapheme

    cond do
      message_fits?(%{message | trailing: candidate}, max_bytes) ->
        {chunks, candidate}

      current == "" ->
        raise ArgumentError, "IRC response overhead leaves no room for one UTF-8 grapheme"

      message_fits?(%{message | trailing: grapheme}, max_bytes) ->
        {[%{message | trailing: current} | chunks], grapheme}

      true ->
        raise ArgumentError, "IRC response overhead leaves no room for one UTF-8 grapheme"
    end
  end

  @spec word_choices(word_choice()) :: [String.t()]
  defp word_choices({preferred, fallback}) when is_binary(preferred) and is_binary(fallback),
    do: Enum.uniq([preferred, fallback])

  defp word_choices(word) when is_binary(word), do: [word]

  @spec choose_word(Message.t(), [String.t()], [String.t()], pos_integer()) ::
          {:current | :new, String.t()} | :error
  defp choose_word(message, current, choices, max_bytes) do
    with nil <- Enum.find(choices, &word_fits?(message, current, &1, max_bytes)),
         false <- current == [],
         word when is_binary(word) <- Enum.find(choices, &word_fits?(message, [], &1, max_bytes)) do
      {:new, word}
    else
      word when is_binary(word) -> {:current, word}
      true -> :error
      nil -> :error
    end
  end

  @spec word_fits?(Message.t(), [String.t()], String.t(), pos_integer()) :: boolean()
  defp word_fits?(message, current, word, max_bytes) do
    message_fits?(%{message | trailing: Enum.join(current ++ [word], " ")}, max_bytes)
  end

  # Nickname equivalences such as ^/~ must not change ident or hostname matching.
  @spec ascii_lower(binary()) :: binary()
  defp ascii_lower(value) do
    for <<byte <- value>>, into: <<>>, do: <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>
  end

  # Match literal IRC globs, retaining only the last star to avoid exponential backtracking.
  @spec match_mask(binary(), binary(), {binary(), binary()} | nil) :: boolean()
  defp match_mask("*" <> mask, value, _retry), do: match_mask(mask, value, {mask, value})
  defp match_mask("", "", _retry), do: true
  defp match_mask("?" <> mask, <<_byte, value::binary>>, retry), do: match_mask(mask, value, retry)
  defp match_mask(<<byte, mask::binary>>, <<byte, value::binary>>, retry), do: match_mask(mask, value, retry)
  defp match_mask(_mask, _value, {mask, <<_byte, value::binary>>}), do: match_mask(mask, value, {mask, value})
  defp match_mask(_mask, _value, _retry), do: false

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
  def user_mask(%{registered: true} = user) when user.nick != nil and user.ident != nil and user.hostname != nil do
    format_user_mask(user.nick, user.ident, display_hostname(user))
  end

  def user_mask(%{registered: false}), do: "*"

  @doc """
  Gets the user mask for registration replies, filling unavailable components
  with wildcards. A precomputed cloak is preferred so registration does not
  disclose a hostname that will be hidden when the connection completes.
  """
  @spec user_mask(User.t(), :registration) :: String.t()
  def user_mask(user, :registration) do
    format_user_mask(user.nick || "*", user.ident || "*", user.cloaked_hostname || user.hostname || "*")
  end

  @doc """
  Gets the ident and visible hostname portion of a registered user's mask.
  """
  @spec user_host(User.t(), User.t() | nil) :: String.t()
  def user_host(%{registered: true} = user, viewer \\ nil)
      when user.ident != nil and user.hostname != nil do
    format_user_host(user.ident, display_hostname(user, viewer))
  end

  @spec format_user_mask(String.t(), String.t(), String.t()) :: String.t()
  defp format_user_mask(nick, ident, hostname), do: "#{nick}!#{format_user_host(ident, hostname)}"

  @spec format_user_host(String.t(), String.t()) :: String.t()
  defp format_user_host(ident, hostname), do: "#{String.slice(ident, 0..9)}@#{hostname}"

  @doc """
  Gets the hostname to display for a user based on +x mode and viewer permissions.
  """
  @spec display_hostname(User.t(), User.t() | nil) :: String.t()
  def display_hostname(user, viewer \\ nil) do
    if :x in user.modes and user.cloaked_hostname != nil and not (viewer != nil and irc_operator?(viewer)) do
      user.cloaked_hostname
    else
      user.hostname
    end
  end

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
  def normalize_mask("$a:" <> account), do: "$a:" <> account
  def normalize_mask("$r:" <> realname), do: "$r:" <> realname
  def normalize_mask("$m:" <> mask), do: "$m:" <> normalize_mask(mask)

  def normalize_mask(mask) do
    {nick, user, host} = parse_mask_parts(mask)
    "#{empty_mask_part_to_wildcard(nick)}!#{empty_mask_part_to_wildcard(user)}@#{empty_mask_part_to_wildcard(host)}"
  end

  @spec empty_mask_part_to_wildcard(String.t()) :: String.t()
  defp empty_mask_part_to_wildcard(""), do: "*"
  defp empty_mask_part_to_wildcard(mask), do: mask

  @doc """
  Validates if a mask has a valid IRC format.
  """
  @spec valid_mask_format?(String.t()) :: boolean()
  def valid_mask_format?(mask) when is_binary(mask) and mask != "" do
    {nick, user, host} = parse_mask_parts(mask)
    valid_mask_part?(nick) and valid_mask_part?(user) and valid_mask_part?(host)
  end

  def valid_mask_format?(_mask), do: false

  @spec parse_mask_parts(String.t()) :: {String.t(), String.t(), String.t()} | :error
  defp parse_mask_parts(mask) do
    case String.split(mask, "@", parts: 2) do
      [nick_user, host] ->
        case String.split(nick_user, "!", parts: 2) do
          [nick, user] -> {nick, user, host}
          [nick_or_user] -> {"*", nick_or_user, host}
        end

      [nick_user] ->
        case String.split(nick_user, "!", parts: 2) do
          [nick, user] -> {nick, user, "*"}
          [nick] -> {nick, "*", "*"}
        end
    end
  end

  @spec valid_mask_part?(String.t()) :: boolean()
  defp valid_mask_part?(part) do
    String.length(part) <= 64 and String.match?(part, ~r/^[a-zA-Z0-9\[\]\\`_^{|}*?.-]+$/)
  end
end
