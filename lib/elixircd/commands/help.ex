defmodule ElixIRCd.Commands.Help do
  @moduledoc "Complete, protocol-visible help catalog for ElixIRCd commands and features."

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @command_help %{
    "ACCEPT" => {"ACCEPT [+|-]<nick>[,...]", "Manages the caller list used by user mode +g."},
    "ADMIN" => {"ADMIN [server]", "Shows the configured server administrator and contact information."},
    "AUTHENTICATE" => {"AUTHENTICATE <mechanism|data|*>", "Runs SASL during CAP negotiation; see HELP SASL."},
    "AWAY" => {"AWAY [:message]", "Sets an away message, or clears away status when no message is supplied."},
    "BATCH" =>
      {"BATCH +<ref> draft/multiline <target> | BATCH -<ref>", "Opens or closes a bounded client multiline batch."},
    "CAP" => {"CAP LS [302] | LIST | REQ :<caps> | END", "Negotiates IRCv3 capabilities before or after registration."},
    "CHATHISTORY" =>
      {"CHATHISTORY <LATEST|BEFORE|AFTER|AROUND> <target> <ref> <limit>",
       "Reads persistent history; BETWEEN accepts two references. See HELP HISTORY."},
    "CHGHOST" => {"CHGHOST <ident> <host>", "Operator command that changes the caller's displayed ident and hostname."},
    "DIE" => {"DIE", "Stops the server. IRC operator privileges are required."},
    "GLOBOPS" => {"GLOBOPS :<message>", "Sends a server-wide notice to IRC operators."},
    "HELP" => {"HELP [topic]", "Shows command and feature documentation. HELP INDEX lists all topics."},
    "HELPOP" => {"HELPOP [topic]", "Alias for HELP."},
    "INFO" => {"INFO [server]", "Shows server software and runtime information."},
    "INVITE" => {"INVITE <nick> <channel>", "Invites a user; channel policy may require operator privileges."},
    "ISON" => {"ISON <nick> [nick ...]", "Returns the supplied nicknames that are currently online."},
    "JOIN" =>
      {"JOIN <channel>[,<channel>...] [key[,key...]] | JOIN 0",
       "Joins channels subject to bans, keys, limits, throttles and channel policy."},
    "KICK" =>
      {"KICK <channel>[,<channel>...] <nick>[,<nick>...] [:reason]",
       "Removes channel members; channel operator privileges are required."},
    "KILL" => {"KILL <nick> :<reason>", "Disconnects a user. IRC operator privileges are required."},
    "LINKS" => {"LINKS [server-mask]", "Shows this standalone server; ElixIRCd intentionally has no S2S links."},
    "LIST" => {"LIST [channels] [elist-options]", "Lists visible channels with safe filtering and pagination limits."},
    "LUSERS" => {"LUSERS", "Shows current local user, operator and channel counts."},
    "MARKREAD" =>
      {"MARKREAD <target> [timestamp=<RFC3339>|msgid=<id>]",
       "Gets or monotonically advances the persistent read marker for a target."},
    "METADATA" =>
      {"METADATA <target> <GET|LIST|SET|CLEAR|SYNC|SUB|UNSUB|SUBS> ...",
       "Stores and synchronizes bounded user/channel metadata. See HELP METADATA."},
    "MODE" =>
      {"MODE <nick|channel> [<+|->modes [parameters...]]",
       "Inspects or changes user, channel and membership modes. See HELP CHANNELMODES."},
    "MONITOR" =>
      {"MONITOR <+|-|C|L|S> [nick[,nick...]]", "Tracks nickname presence up to the advertised MONITOR limit."},
    "MOTD" => {"MOTD [server]", "Shows the server message of the day."},
    "NAMES" => {"NAMES [channel[,channel...]]", "Lists visible channel members and negotiated membership prefixes."},
    "NICK" => {"NICK <nickname>", "Sets or changes a nickname, subject to reservation and +N channel policy."},
    "NOTICE" => {"NOTICE <target>[,<target>...] :<text>", "Sends a non-error-generating notice to users or channels."},
    "OPER" => {"OPER <name> <password>", "Authenticates an IRC operator using the configured Argon2 credential."},
    "OPERWALL" => {"OPERWALL :<message>", "Sends an operator wall message."},
    "PART" => {"PART <channel>[,<channel>...] [:reason]", "Leaves one or more channels."},
    "PASS" => {"PASS <password>", "Supplies the optional server password before registration."},
    "PING" => {"PING <token>", "Requests a PONG carrying the supplied token."},
    "PONG" => {"PONG <token>", "Responds to server keepalive probes."},
    "PRIVMSG" =>
      {"PRIVMSG <target>[,<target>...] :<text>",
       "Sends a message after channel, silence, consent and target-limit checks."},
    "QUIT" => {"QUIT [:reason]", "Disconnects and notifies visible shared-channel users."},
    "REDACT" =>
      {"REDACT <target> <msgid> [:reason]", "Redacts an authorized persisted message and notifies capable clients."},
    "REGISTER" =>
      {"REGISTER * <email|*> <password>",
       "Creates a services account; email registrations require VERIFY before login."},
    "REHASH" => {"REHASH", "Atomically validates and reloads supported configuration; IRC operator only."},
    "RENAME" =>
      {"RENAME <old-channel> <new-channel> [:reason]",
       "Atomically renames a channel and all local persistent references."},
    "RESTART" => {"RESTART", "Restarts the server. IRC operator privileges are required."},
    "SETNAME" => {"SETNAME :<realname>", "Changes the caller's real name and notifies capable shared-channel users."},
    "SILENCE" =>
      {"SILENCE [+|-]<mask> | SILENCE", "Manages masks whose private messages and notices are silently ignored."},
    "STATS" =>
      {"STATS <query> [server]", "Shows bounded server statistics; sensitive queries require operator privileges."},
    "TAGMSG" => {"TAGMSG <target>[,<target>...]", "Sends a tag-only message to message-tags capable recipients."},
    "TIME" => {"TIME [server]", "Shows the server's current time."},
    "TOPIC" => {"TOPIC <channel> [:topic]", "Reads or changes a topic, respecting +t and ChanServ topic locks."},
    "TRACE" => {"TRACE [target]", "Shows local connection trace information with operator-aware privacy."},
    "USER" => {"USER <ident> 0 * :<realname>", "Supplies registration identity fields."},
    "USERHOST" => {"USERHOST <nick> [nick ...]", "Shows compact identity, away and operator information."},
    "USERS" => {"USERS", "Shows local users using the traditional USERS reply format."},
    "VERIFY" => {"VERIFY <account|*> <code>", "Completes email verification and authenticates the account."},
    "VERSION" => {"VERSION [server]", "Shows the ElixIRCd version and advertised feature tokens."},
    "WALLOPS" => {"WALLOPS :<message>", "Sends a message to users with wallops mode +w; IRC operator only."},
    "WEBIRC" =>
      {"WEBIRC <password> <gateway> <hostname> <ip> [options]",
       "Trusted-proxy command validated against configured gateway and address policy."},
    "WHO" => {"WHO [mask] [%<fields>[,<token>]]", "Lists visible users; supports WHOX fields and response tokens."},
    "WHOIS" =>
      {"WHOIS [server] <nick>", "Shows visible identity, account, channels, modes, metadata and idle information."},
    "WHOWAS" => {"WHOWAS <nick> [count] [server]", "Looks up bounded recent nickname history."}
  }

  @feature_help %{
    "CAPABILITIES" => [
      "Use CAP LS 302 for the authoritative capability list and values.",
      "Dependencies are enforced: labeled-response needs batch; history, metadata and multiline require companion capabilities.",
      "Capabilities may change after REHASH through CAP NEW and CAP DEL."
    ],
    "CHANNELMODES" => [
      "Lists: +b bans, +e ban exceptions, +I invite exceptions.",
      "Parameters: +k key, +l user limit, +j joins:seconds throttle, +d speak delay.",
      "Policy: +i invite-only, +m moderated, +n no external messages, +t operator topic, +p private, +s secret.",
      "Identity/security: +r registered channel, +R registered-only join, +M registered-only speak, +z TLS-only join, +O IRC-operator-only join.",
      "Content/visibility: +C blocks CTCP, +c blocks formatting, +T blocks notices, +u auditorium, +U op-moderated, +N blocks unprivileged nick changes.",
      "Membership: +o operator and +v voice. MODE <channel> b/e/I lists entries."
    ],
    "USERMODES" => [
      "+B bot, +g caller-ID, +H hidden operator, +i invisible, +o IRC operator, +r identified, +R registered-only private messages.",
      "+s server notices, +w wallops, +x cloaked hostname, +Z secure transport. Server-managed modes cannot be self-granted."
    ],
    "EXTBANS" => [
      "+b $a:<account-glob> bans by authenticated account; $r:<realname-glob> bans by real name.",
      "+b $m:<mask-or-extban> mutes matching users without preventing JOIN. Matching +e entries bypass bans and mutes.",
      "Nick!ident@host masks support * and ? and use the configured CASEMAPPING for nicknames."
    ],
    "HISTORY" => [
      "References are *, msgid=<id>, or timestamp=<RFC3339>. Limits are capped by CHATHISTORY in ISUPPORT.",
      "History is persistent, retention-bounded and scoped to current channel membership or authenticated direct-message identity.",
      "draft/event-playback adds JOIN, PART, KICK, MODE, NICK, QUIT and TOPIC events; redacted entries are omitted.",
      "Multiline is stored and replayed as a nested draft/multiline batch with stable msgid and time."
    ],
    "METADATA" => [
      "GET/LIST read keys; SET sets or removes a key; CLEAR removes keys; SUB/UNSUB/SUBS manage notifications; SYNC refreshes subscriptions.",
      "Account and channel metadata are durable. Unauthenticated user metadata is connection-scoped to prevent nickname takeover leaks.",
      "Limits and before-connect support are advertised on draft/metadata-2 and its draft/metadata-3 compatibility alias."
    ],
    "SASL" => [
      "Supported mechanisms are advertised in CAP LS. PLAIN may require TLS; SCRAM-SHA-256 never sends a reusable password.",
      "SCRAM uses PBKDF2-HMAC-SHA-256 with per-account salt; legacy Argon2 accounts upgrade after verified login.",
      "Use CAP REQ :sasl, AUTHENTICATE <mechanism>, complete authentication, then CAP END."
    ],
    "SERVICES" => [
      "NickServ manages accounts, nick ownership, access lists, memos, email verification and authentication.",
      "ChanServ manages channel registration, access flags, settings, mode locks, topics and operator actions.",
      "Use /msg NickServ HELP or /msg ChanServ HELP for their complete command catalogs."
    ],
    "TRANSPORTS" => [
      "The same IRC protocol is available on TCP, TLS, WebSocket and secure WebSocket listeners.",
      "STS can direct plaintext clients to TLS. WEBIRC is accepted only from configured trusted gateways."
    ]
  }

  @doc "Returns the command help catalog for completeness tests and documentation tooling."
  @spec command_topics() :: %{String.t() => {String.t(), String.t()}}
  def command_topics, do: @command_help

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: _command}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: command, params: params}) when command in ["HELP", "HELPOP"] do
    subject = params |> Enum.join(" ") |> String.trim() |> normalize_subject()

    cond do
      subject == "INDEX" ->
        send_index(user)

      Map.has_key?(@command_help, subject) ->
        send_command_help(user, subject, Map.fetch!(@command_help, subject))

      Map.has_key?(@feature_help, subject) ->
        send_lines(user, subject, "ElixIRCd #{String.downcase(subject)}", @feature_help[subject])

      true ->
        send_not_found(user, subject)
    end
  end

  defp normalize_subject(""), do: "INDEX"
  defp normalize_subject(subject), do: String.upcase(subject)

  defp send_index(user) do
    commands = Command.names() |> Enum.chunk_every(10) |> Enum.map(&("Commands: " <> Enum.join(&1, " ")))
    features = "Topics: " <> (@feature_help |> Map.keys() |> Enum.sort() |> Enum.join(" "))
    send_lines(user, "INDEX", "ElixIRCd help index", commands ++ [features, "Use HELP <command-or-topic> for details."])
  end

  defp send_command_help(user, subject, {syntax, description}) do
    send_lines(user, subject, description, ["Syntax: " <> syntax, related_help(subject)])
  end

  defp related_help(subject) when subject in ["MODE", "JOIN", "KICK", "TOPIC"],
    do: "Related: HELP CHANNELMODES and HELP EXTBANS"

  defp related_help(subject) when subject in ["CHATHISTORY", "MARKREAD", "REDACT", "BATCH"],
    do: "Related: HELP HISTORY"

  defp related_help("METADATA"), do: "Related: HELP METADATA"

  defp related_help(subject) when subject in ["CAP", "AUTHENTICATE", "REGISTER", "VERIFY"],
    do: "Related: HELP CAPABILITIES and HELP SASL"

  defp related_help(_subject), do: "Use HELP INDEX to browse all commands and feature topics."

  defp send_lines(user, subject, summary, lines) do
    ([%Message{command: :rpl_helpstart, params: [user.nick, subject], trailing: summary}] ++
       Enum.map(lines, &%Message{command: :rpl_helptxt, params: [user.nick, subject], trailing: &1}) ++
       [%Message{command: :rpl_endofhelp, params: [user.nick, subject], trailing: "End of HELP"}])
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_not_found(user, subject) do
    %Message{command: :err_helpnotfound, params: [user.nick, subject], trailing: "No help available"}
    |> Dispatcher.broadcast(:server, user)
  end
end
