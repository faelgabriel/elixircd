defmodule ElixIRCd.Services.Nickserv.Help do
  @moduledoc """
  This module defines the NickServ HELP command.

  HELP provides assistance and documentation for NickServ commands.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [notify: 2, email_required_format: 1]

  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["HELP" | rest_params]) do
    normalized_command =
      rest_params
      |> Enum.join(" ")
      |> String.upcase()

    send_help_for_command(user, normalized_command)
  end

  @spec send_help_for_command(User.t(), String.t()) :: :ok
  defp send_help_for_command(user, ""), do: send_general_help(user)
  defp send_help_for_command(user, "REGISTER"), do: send_register_help(user)
  defp send_help_for_command(user, "VERIFY"), do: send_verify_help(user)
  defp send_help_for_command(user, "IDENTIFY"), do: send_identify_help(user)
  defp send_help_for_command(user, "LOGOUT"), do: send_logout_help(user)
  defp send_help_for_command(user, "GHOST"), do: send_ghost_help(user)
  defp send_help_for_command(user, "RECOVER"), do: send_recover_help(user)
  defp send_help_for_command(user, "REGAIN"), do: send_regain_help(user)
  defp send_help_for_command(user, "RELEASE"), do: send_release_help(user)
  defp send_help_for_command(user, "DROP"), do: send_drop_help(user)
  defp send_help_for_command(user, "INFO"), do: send_info_help(user)
  defp send_help_for_command(user, "LIST"), do: send_list_help(user)
  defp send_help_for_command(user, "MEMO"), do: send_memo_help(user)
  defp send_help_for_command(user, "SET"), do: send_set_help(user)
  defp send_help_for_command(user, "SET HIDEMAIL"), do: send_set_hidemail_help(user)

  defp send_help_for_command(user, "SET HIDESTATUS"),
    do: send_set_option_help(user, "HIDESTATUS", "{ON|OFF}", "Hides online status in INFO displays.")

  defp send_help_for_command(user, "SET HIDEUSERMASK"),
    do: send_set_option_help(user, "HIDEUSERMASK", "{ON|OFF}", "Hides the registration mask in INFO displays.")

  defp send_help_for_command(user, "SET HIDEQUIT"),
    do: send_set_option_help(user, "HIDEQUIT", "{ON|OFF}", "Hides last-seen information in INFO displays.")

  defp send_help_for_command(user, "SET ENFORCE"),
    do: send_set_option_help(user, "ENFORCE", "{ON|OFF}", "Enforces ownership of your registered nickname.")

  defp send_help_for_command(user, "SET NEVERGROUP"),
    do:
      send_set_option_help(
        user,
        "NEVERGROUP",
        "{ON|OFF}",
        "Prevents other nicknames from being grouped into your account."
      )

  defp send_help_for_command(user, "SET NEVEROP"),
    do:
      send_set_option_help(
        user,
        "NEVEROP",
        "{ON|OFF}",
        "Prevents ChanServ SYNC from automatically giving you operator status."
      )

  defp send_help_for_command(user, "SET NOGREET"),
    do:
      send_set_option_help(
        user,
        "NOGREET",
        "{ON|OFF}",
        "Suppresses registered-channel entry messages for your account."
      )

  defp send_help_for_command(user, "SET PRIVATE"),
    do:
      send_set_option_help(
        user,
        "PRIVATE",
        "{ON|OFF}",
        "Hides your registered nicknames from public NickServ LIST results."
      )

  defp send_help_for_command(user, "SET QUIETCHG"),
    do:
      send_set_option_help(
        user,
        "QUIETCHG",
        "{ON|OFF}",
        "Suppresses automatic ChanServ mode and flag changes for your session."
      )

  defp send_help_for_command(user, "SET SECURE"),
    do: send_set_option_help(user, "SECURE", "{ON|OFF}", "Requires TLS for password authentication to your account.")

  defp send_help_for_command(user, "SET MSG"),
    do: send_set_option_help(user, "MSG", "{ON|OFF}", "Uses PRIVMSG instead of NOTICE for NickServ replies.")

  defp send_help_for_command(user, "SET EMAIL"),
    do: send_set_option_help(user, "EMAIL", "<email-address> or OFF", "Changes or removes the account email address.")

  defp send_help_for_command(user, "SET EMAILMEMOS"),
    do: send_set_option_help(user, "EMAILMEMOS", "{ON|OFF|ONLY}", "Controls whether memos are also forwarded by email.")

  defp send_help_for_command(user, "SET ENFORCETIME"),
    do:
      send_set_option_help(
        user,
        "ENFORCETIME",
        "<seconds>",
        "Sets the normal grace period before nickname enforcement; zero requests immediate enforcement."
      )

  defp send_help_for_command(user, "SET LANGUAGE"),
    do: send_set_option_help(user, "LANGUAGE", "<language>", "Sets the NickServ language preference (en or pt-BR).")

  defp send_help_for_command(user, "SET KILL"),
    do:
      send_set_option_help(
        user,
        "KILL",
        "{ON|QUICK|IMMED|OFF}",
        "Selects the enforcement action: ON uses ENFORCETIME, QUICK caps it at the network quick interval, IMMED acts immediately, and OFF forces a guest nickname after ENFORCETIME."
      )

  defp send_help_for_command(user, "SET PROPERTY"),
    do:
      send_set_option_help(
        user,
        "PROPERTY",
        "<name> [value|OFF]",
        "Stores, queries, lists, or removes account metadata."
      )

  defp send_help_for_command(user, "SET PUBKEY"),
    do:
      send_set_option_help(
        user,
        "PUBKEY",
        "[base64-key|OFF]",
        "Stores the account public key used by supported authentication mechanisms."
      )

  defp send_help_for_command(user, "SET URL"),
    do: send_set_option_help(user, "URL", "<url> or OFF", "Associates a website with the account.")

  defp send_help_for_command(user, "SET DISPLAY"),
    do:
      send_set_option_help(
        user,
        "DISPLAY",
        "<nickname> or OFF",
        "Sets the display nickname from your grouped nicknames."
      )

  defp send_help_for_command(user, "ACCESS"), do: send_access_help(user)
  defp send_help_for_command(user, "ALIST"), do: send_alist_help(user)
  defp send_help_for_command(user, "STATUS"), do: send_status_help(user)
  defp send_help_for_command(user, "GROUP"), do: send_group_help(user)
  defp send_help_for_command(user, "UNGROUP"), do: send_ungroup_help(user)
  defp send_help_for_command(user, "LISTCHANS"), do: send_listchans_help(user)
  defp send_help_for_command(user, "FAQ"), do: send_faq_help(user)
  defp send_help_for_command(user, command), do: send_unknown_command_help(user, command)

  @spec send_general_help(User.t()) :: :ok
  defp send_general_help(user) do
    notify(user, ["NickServ help:"])
    notify(user, general_help())
    notify(user, ["For more information on a command, type \x02/msg NickServ HELP <command>\x02"])
  end

  @spec send_register_help(User.t()) :: :ok
  defp send_register_help(user) do
    min_password_length = Application.fetch_env!(:elixircd, :services)[:nickserv][:min_password_length]
    email_required? = Application.fetch_env!(:elixircd, :services)[:nickserv][:email_required]
    wait_register_time = Application.fetch_env!(:elixircd, :services)[:nickserv][:wait_register_time]

    notify(user, [
      "Help for \x02REGISTER\x02:",
      format_help(
        "REGISTER",
        ["<password> #{email_required_format(email_required?)}"],
        "Registers your current nickname."
      ),
      "",
      "This will register your current nickname with NickServ.",
      "This will allow you to assert some form of identity on the network",
      "and to be added to access lists. Furthermore, NickServ will warn",
      "users using your nick without identifying and allow you to kill ghosts."
    ])

    if wait_register_time > 0 do
      notify(user, [
        "",
        "You must be connected for at least #{wait_register_time} seconds",
        "before you can register your nickname."
      ])
    end

    if email_required? do
      notify(user, [
        "",
        "This server REQUIRES an email address for registration.",
        "You have to confirm the email address. To do this, follow",
        "the instructions in the message sent to the email address."
      ])
    else
      notify(user, [
        "",
        "An email address is optional but recommended. If provided,",
        "you can use it to reset your password if you forget it."
      ])
    end

    notify(user, [
      "",
      "Your password must be at least #{min_password_length} characters long.",
      "Please write down or memorize your password! You will need it later",
      "to change settings. The password is case-sensitive.",
      "",
      "Syntax: \x02REGISTER <password> #{email_required_format(email_required?)}\x02",
      "",
      "Example:",
      "    \x02/msg NickServ REGISTER mypassword user@example.com\x02"
    ])
  end

  @spec send_verify_help(User.t()) :: :ok
  defp send_verify_help(user) do
    notify(user, [
      "Help for \x02VERIFY\x02:",
      format_help("VERIFY", ["nickname code"], "Verifies a registered nickname."),
      "",
      "This command completes the registration process for your nickname.",
      "You will receive a verification code when you register.",
      "",
      "Syntax: \x02VERIFY nickname code\x02",
      "",
      "Example:",
      "    \x02/msg NickServ VERIFY mynick abc123def456\x02"
    ])
  end

  @spec send_identify_help(User.t()) :: :ok
  defp send_identify_help(user) do
    notify(user, [
      "Help for \x02IDENTIFY\x02:",
      format_help("IDENTIFY", ["[nickname] <password>"], "Identifies you with your account."),
      "",
      "This will identify your current session to NickServ, giving you",
      "access to all privileges granted to your account.",
      "",
      "If you specify a nickname, you will identify to that account",
      "instead of the account matching your current nickname.",
      "",
      "When identifying to a nickname that doesn't match your current nick,",
      "your current nick will be recognized as belonging to that account.",
      "",
      "Syntax: \x02IDENTIFY [nickname] <password>\x02",
      "",
      "Examples:",
      "    \x02/msg NickServ IDENTIFY mypassword\x02",
      "    \x02/msg NickServ IDENTIFY MyNick mypassword\x02"
    ])
  end

  @spec send_logout_help(User.t()) :: :ok
  defp send_logout_help(user) do
    notify(user, [
      "Help for \x02LOGOUT\x02:",
      format_help("LOGOUT", [], "Logs you out from your current account."),
      "",
      "This command logs you out from your current NickServ account,",
      "removing your authenticated status and any privileges associated",
      "with your account. You will need to identify again to regain access.",
      "",
      "Syntax: \x02LOGOUT\x02",
      "",
      "Example:",
      "    \x02/msg NickServ LOGOUT\x02"
    ])
  end

  @spec send_ghost_help(User.t()) :: :ok
  defp send_ghost_help(user) do
    notify(user, [
      "Help for \x02GHOST\x02:",
      format_help("GHOST", ["<nick> [password]"], "Kills a ghost session using your nickname."),
      "",
      "The GHOST command allows you to disconnect an old or",
      "unauthorized session that's using your registered nickname.",
      "",
      "If you're identified to a nickname, you can use this command",
      "without a password to ghost anyone using that nickname.",
      "",
      "If you're not identified, you'll need to provide the correct",
      "password for the nickname you're trying to ghost.",
      "",
      "Syntax: \x02GHOST <nick> [password]\x02",
      "",
      "Example:",
      "    \x02/msg NickServ GHOST MyNick MyPassword\x02"
    ])
  end

  @spec send_regain_help(User.t()) :: :ok
  defp send_regain_help(user) do
    notify(user, [
      "Help for \x02REGAIN\x02:",
      format_help("REGAIN", ["<nickname> <password>"], "Regains a nickname you own and are not currently using."),
      "",
      "This command disconnects another user who is using your",
      "nickname and reserves it for you. You must then take it",
      "yourself with /NICK (identify first if needed).",
      "",
      "If the nickname is not currently in use, it simply changes",
      "your nickname. If you are already identified to the nickname,",
      "you don't need to specify a password.",
      "",
      "Syntax: \x02REGAIN <nickname> <password>\x02",
      "",
      "Example:",
      "    \x02/msg NickServ REGAIN MyNick MyPassword\x02"
    ])
  end

  @spec send_release_help(User.t()) :: :ok
  defp send_release_help(user) do
    notify(user, [
      "Help for \x02RELEASE\x02:",
      format_help("RELEASE", ["<nickname> <password>"], "Releases a held nickname."),
      "",
      "This command releases a nickname that was reserved by the",
      "REGAIN or RECOVER commands, making it available for anyone to use.",
      "",
      "You must be identified to the nickname or provide its",
      "correct password to release it.",
      "",
      "Syntax: \x02RELEASE <nickname> <password>\x02",
      "",
      "Example:",
      "    \x02/msg NickServ RELEASE MyNick MyPassword\x02"
    ])
  end

  @spec send_recover_help(User.t()) :: :ok
  defp send_recover_help(user) do
    recover_reservation_duration =
      Application.fetch_env!(:elixircd, :services)[:nickserv][:recover_reservation_duration]

    notify(user, [
      "Help for \x02RECOVER\x02:",
      format_help(
        "RECOVER",
        ["<nickname> <password>"],
        "Forcefully disconnects another user and reserves your nickname."
      ),
      "",
      "This command disconnects a user who is using your registered",
      "nickname and reserves it for you. Unlike REGAIN, it does not",
      "automatically change your nickname - you must identify and",
      "change it manually.",
      "",
      "The nickname will be held exclusively for you for",
      "#{recover_reservation_duration} seconds, giving you time to identify and claim it.",
      "",
      "If you are already identified to the nickname, you don't need",
      "to specify a password. Otherwise, you must provide the correct",
      "password for the nickname you're trying to recover.",
      "",
      "After recovery, you must:",
      "  1. Identify with: \x02/msg NickServ IDENTIFY <nickname> <password>\x02",
      "  2. Change your nick: \x02/NICK <nickname>\x02",
      "",
      "Syntax: \x02RECOVER <nickname> <password>\x02",
      "",
      "Example:",
      "    \x02/msg NickServ RECOVER MyNick MyPassword\x02"
    ])
  end

  @spec send_drop_help(User.t()) :: :ok
  defp send_drop_help(user) do
    notify(user, [
      "Help for \x02DROP\x02:",
      format_help("DROP", ["<nickname> [password]"], "Unregisters a nickname."),
      "",
      "This command deletes the registration for a nickname,",
      "removing it and all related access, making it available",
      "for registration by anyone again.",
      "",
      "If you are identified to the nickname you want to drop,",
      "you don't need to provide a password. Otherwise, you must",
      "provide the nickname's password.",
      "",
      "If you don't specify a nickname, your current nick will be dropped.",
      "",
      "Syntax: \x02DROP <nickname> [password]\x02",
      "",
      "Examples:",
      "    \x02/msg NickServ DROP\x02",
      "    \x02/msg NickServ DROP MyNick\x02",
      "    \x02/msg NickServ DROP MyOtherNick MyPassword\x02"
    ])
  end

  @spec send_info_help(User.t()) :: :ok
  defp send_info_help(user) do
    notify(user, [
      "Help for \x02INFO\x02:",
      format_help("INFO", ["[nickname]"], "Displays information about a registered nickname."),
      "",
      "This command displays information about a registered nickname,",
      "such as its registration date, last seen time, and options.",
      "",
      "If you don't specify a nickname, information about your",
      "current nickname will be displayed.",
      "",
      "If the server has privacy features enabled, some information",
      "may be hidden unless you are identified to the nickname or",
      "are an IRC operator.",
      "",
      "Syntax: \x02INFO [nickname]\x02",
      "",
      "Examples:",
      "    \x02/msg NickServ INFO\x02",
      "    \x02/msg NickServ INFO SomeNick\x02"
    ])
  end

  @spec send_list_help(User.t()) :: :ok
  defp send_list_help(user) do
    notify(user, [
      "Help for \x02LIST\x02:",
      format_help("LIST", ["[pattern]"], "Lists registered nicknames."),
      "",
      "LIST shows registered nicknames matching an optional * wildcard pattern.",
      "Accounts marked PRIVATE are hidden from other users and remain visible",
      "to the account owner and IRC operators.",
      "",
      "Syntax: \x02LIST [pattern]\x02",
      "Example: \x02/msg NickServ LIST *admin*\x02"
    ])
  end

  @spec send_memo_help(User.t()) :: :ok
  defp send_memo_help(user) do
    notify(user, [
      "Help for \x02MEMO\x02:",
      format_help("MEMO", ["{SEND|LIST|READ|DEL|CLEAR}"], "Sends and manages account memos."),
      "",
      "MEMO SEND stores a message in the recipient's NickServ inbox.",
      "EMAILMEMOS ON also queues a copy for email delivery; ONLY sends",
      "only by email and does not retain an inbox copy.",
      "",
      "Syntax: \x02MEMO SEND <nickname> <message>\x02",
      "Syntax: \x02MEMO LIST|READ <id>|DEL <id>|CLEAR\x02"
    ])
  end

  @spec send_faq_help(User.t()) :: :ok
  defp send_faq_help(user) do
    unverified_expire_days = Application.fetch_env!(:elixircd, :services)[:nickserv][:unverified_expire_days]
    wait_register_time = Application.fetch_env!(:elixircd, :services)[:nickserv][:wait_register_time]

    notify(user, [
      "Help for \x02FAQ\x02:",
      "",
      "Frequently Asked Questions:",
      "",
      "Q: Why should I register my nickname?",
      "A: Registering your nickname helps you maintain a unique",
      "   identity on the network and prevents others from using it.",
      "",
      "Q: I forgot my password. What can I do?",
      "A: You need to contact a network administrator to reset it.",
      "",
      "Q: My nickname has expired. Can I get it back?",
      "A: If your nickname has expired due to inactivity, you can",
      "   simply register it again. Nicknames expire after",
      "   #{Application.fetch_env!(:elixircd, :services)[:nickserv][:nick_expire_days]} days of inactivity."
    ])

    # Add information about unverified nickname expiration if enabled
    if unverified_expire_days > 0 do
      notify(user, [
        "",
        "Q: How long do I have to verify my nickname after registration?",
        "A: You must verify your nickname within #{unverified_expire_days} #{pluralize_days(unverified_expire_days)}",
        "   after registration or it will expire and you'll need to register again."
      ])
    end

    notify(user, [
      "",
      "Q: What does it mean to \x02identify\x02?",
      "A: Identifying means proving to NickServ that you are the",
      "   owner of a registered nickname by providing the correct",
      "   password with the \x02IDENTIFY\x02 command."
    ])

    # Add information about wait time for registration if enabled
    if wait_register_time > 0 do
      notify(user, [
        "",
        "Q: Why can't I register my nickname immediately after connecting?",
        "A: This server requires you to be connected for at least",
        "   #{wait_register_time} seconds before you can register a nickname.",
        "   This is to prevent abuse of the registration system."
      ])
    end
  end

  @spec send_unknown_command_help(User.t(), String.t()) :: :ok
  defp send_unknown_command_help(user, command) do
    notify(user, [
      "Help for \x02#{command}\x02 is not available.",
      "For a list of available commands, type \x02/msg NickServ HELP\x02"
    ])
  end

  @spec general_help() :: [String.t()]
  defp general_help do
    nick_expire_days = Application.fetch_env!(:elixircd, :services)[:nickserv][:nick_expire_days]

    [
      "NickServ allows you to register and manage your nickname.",
      "Nicknames that remain unused for #{nick_expire_days} days may expire.",
      "",
      "The following commands are available:",
      "\x02REGISTER\x02     - Register a nickname",
      "\x02IDENTIFY\x02     - Identify to your nickname",
      "\x02LOGOUT\x02       - Log out from your current account",
      "\x02VERIFY\x02       - Verify a registered nickname",
      "\x02GHOST\x02        - Kill a ghost session using your nickname",
      "\x02RECOVER\x02      - Recover your nickname and reserve it",
      "\x02REGAIN\x02       - Regain your nickname from another user",
      "\x02RELEASE\x02      - Release a held nickname",
      "\x02DROP\x02         - Unregister a nickname",
      "\x02INFO\x02         - Display information about a nickname",
      "\x02LIST\x02         - List registered nicknames",
      "\x02MEMO\x02         - Send and manage account memos",
      "\x02SET\x02          - Set nickname options and information",
      "\x02ACCESS\x02       - Manage your access list",
      "\x02ALIST\x02        - List accounts you are recognized for",
      "\x02STATUS\x02       - Check authentication status of nicknames",
      "\x02GROUP\x02        - Group your current nick into your account",
      "\x02UNGROUP\x02      - Remove your current nick from your account",
      "\x02LISTCHANS\x02    - List channels where your account is founder or successor",
      "",
      "For more information on a command, type \x02/msg NickServ HELP <command>\x02"
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec format_help(String.t(), [String.t()], String.t()) :: String.t()
  defp format_help(command, syntax, description) do
    syntax_str = Enum.join(syntax, " or ")
    "\x02#{command} #{syntax_str}\x02 - #{description}"
  end

  @spec pluralize_days(integer()) :: String.t()
  defp pluralize_days(1), do: "day"
  defp pluralize_days(_), do: "days"

  @spec send_set_help(User.t()) :: :ok
  defp send_set_help(user) do
    notify(user, [
      "Help for \x02SET\x02:",
      format_help("SET", ["<option> <parameters>"], "Sets various nickname options."),
      "",
      "This command allows you to set various options for your",
      "registered nickname. The available options are:",
      "",
      "\x02EMAIL\x02        - Change or remove your account email",
      "\x02EMAILMEMOS\x02   - Control memo email delivery",
      "\x02ENFORCE\x02      - Enforce ownership of your nickname",
      "\x02ENFORCETIME\x02  - Set nickname enforcement grace time",
      "\x02LANGUAGE\x02     - Set the NickServ language",
      "\x02KILL\x02         - Select enforcement action",
      "\x02PROPERTY\x02     - Manage account metadata",
      "\x02PUBKEY\x02       - Manage the account public key",
      "\x02URL\x02          - Set the account website",
      "\x02DISPLAY\x02      - Set the grouped display nickname",
      "\x02HIDEMAIL\x02     - Hide your email address in INFO displays",
      "\x02HIDESTATUS\x02   - Hide online status in INFO displays",
      "\x02HIDEUSERMASK\x02 - Hide the registration mask",
      "\x02HIDEQUIT\x02     - Hide last-seen information",
      "\x02MSG\x02          - Use PRIVMSG for NickServ replies",
      "\x02NEVERGROUP\x02  - Disable account grouping",
      "\x02NEVEROP\x02     - Disable automatic ChanServ op",
      "\x02NOGREET\x02     - Suppress channel entry messages",
      "\x02PRIVATE\x02     - Hide nicknames from NickServ LIST",
      "\x02QUIETCHG\x02   - Suppress automatic ChanServ mode and flag changes",
      "\x02SECURE\x02     - Require TLS for authentication",
      "",
      "For more information on a specific option, type",
      "\x02/msg NickServ HELP SET <option>\x02",
      "",
      "Syntax: \x02SET <option> <parameters>\x02",
      "",
      "Example:",
      "    \x02/msg NickServ SET HIDEMAIL ON\x02"
    ])
  end

  @spec send_set_option_help(User.t(), String.t(), String.t(), String.t()) :: :ok
  defp send_set_option_help(user, option, syntax, description) do
    notify(user, [
      "Help for \x02SET #{option}\x02:",
      format_help("SET #{option}", [syntax], description),
      "",
      "The setting is stored on your canonical account and applies to",
      "all grouped nicknames.",
      "",
      "Syntax: \x02SET #{option} #{syntax}\x02"
    ])
  end

  @spec send_set_hidemail_help(User.t()) :: :ok
  defp send_set_hidemail_help(user) do
    notify(user, [
      "Help for \x02SET HIDEMAIL\x02:",
      format_help("SET HIDEMAIL", ["{ON|OFF}"], "Hides your email address in INFO displays."),
      "",
      "This option allows you to hide your email address from being",
      "displayed when someone requests information about your nickname.",
      "",
      "When set to ON, your email address will be hidden from everyone",
      "except for yourself and IRC operators.",
      "",
      "When set to OFF, your email address will be visible to anyone who",
      "has sufficient privileges to view your nickname information.",
      "",
      "Syntax: \x02SET HIDEMAIL {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg NickServ SET HIDEMAIL ON\x02"
    ])
  end

  @spec send_access_help(User.t()) :: :ok
  defp send_access_help(user) do
    max_access_entries = Application.fetch_env!(:elixircd, :services)[:nickserv][:max_access_entries]

    notify(user, [
      "Help for \x02ACCESS\x02:",
      format_help("ACCESS", ["{ADD|DEL|LIST|CLEAR} [mask]"], "Manages your access list."),
      "",
      "The ACCESS list allows you to maintain a list of authorized",
      "host masks (user@host) for your nickname. This can be used for",
      "authentication and security purposes.",
      "",
      "Available subcommands:",
      "",
      "\x02ACCESS ADD <mask>\x02",
      "    Adds a host mask to your access list.",
      "    The mask must be in the format: [ident]@host",
      "    Wildcards * (any string) and ? (one character) are allowed.",
      "    Example: *@trusted.vpn, user@192.168.1.1, ~user@*.example.com",
      "",
      "\x02ACCESS DEL <mask>\x02",
      "    Removes a host mask from your access list.",
      "    The mask must match exactly (case-insensitive).",
      "",
      "\x02ACCESS LIST\x02",
      "    Displays all masks in your access list with their creation dates.",
      "",
      "\x02ACCESS CLEAR\x02",
      "    Removes all entries from your access list.",
      "",
      "You can have a maximum of \x02#{max_access_entries}\x02 entries in your access list.",
      "",
      "\x1FSECURITY WARNING:\x1F",
      "Be careful with overly broad masks like *@*.isp.com or *@*.",
      "Using wildcards on dynamic IPs or shared VPNs can be a security risk.",
      "Always use the most specific mask possible for your situation.",
      "",
      "Syntax: \x02ACCESS {ADD|DEL|LIST|CLEAR} [mask]\x02",
      "",
      "Examples:",
      "    \x02/msg NickServ ACCESS ADD *@trusted.vpn\x02",
      "    \x02/msg NickServ ACCESS LIST\x02",
      "    \x02/msg NickServ ACCESS DEL *@trusted.vpn\x02"
    ])
  end

  @spec send_alist_help(User.t()) :: :ok
  defp send_alist_help(user) do
    notify(user, [
      "Help for \x02ALIST\x02:",
      format_help("ALIST", [], "Lists accounts you are recognized for."),
      "",
      "ALIST shows all registered accounts that NickServ considers",
      "associated with your current connection. This includes:",
      "",
      "  • Your currently authenticated account (if any)",
      "  • Accounts whose ACCESS list matches your user@host",
      "  • Accounts linked via SASL authentication",
      "",
      "This command helps you understand which accounts NickServ",
      "recognizes you for, based on your current identity markers.",
      "",
      "\x1FIMPORTANT:\x1F This does NOT mean you control all listed accounts.",
      "It only shows accounts that trust something you're using right now",
      "(your host, authenticated session, etc.).",
      "",
      "Syntax: \x02ALIST\x02",
      "",
      "Example:",
      "    \x02/msg NickServ ALIST\x02"
    ])
  end

  @spec send_status_help(User.t()) :: :ok
  defp send_status_help(user) do
    notify(user, [
      "Help for \x02STATUS\x02:",
      format_help("STATUS", ["<nickname> [nickname2 ...]"], "Checks authentication status."),
      "",
      "This command checks the authentication status of one or more nicknames.",
      "It returns a status code indicating the level of authentication:",
      "",
      "  \x020\x02 - Nickname is not registered",
      "  \x021\x02 - Nickname is registered but not authenticated",
      "  \x022\x02 - Authenticated but not trusted (no ACCESS match)",
      "  \x023\x02 - Authenticated and trusted (via ACCESS or SASL)",
      "",
      "This command is useful for checking if someone is properly",
      "identified before granting them privileges or permissions.",
      "",
      "Syntax: \x02STATUS <nickname> [nickname2 ...]\x02",
      "",
      "Examples:",
      "    \x02/msg NickServ STATUS Alice\x02",
      "    \x02/msg NickServ STATUS Alice Bob Charlie\x02"
    ])
  end

  @spec send_group_help(User.t()) :: :ok
  defp send_group_help(user) do
    notify(user, [
      "Help for \x02GROUP\x02:",
      format_help(
        "GROUP",
        ["[current-nick-password]"],
        "Groups your current nickname into the account you are identified to."
      ),
      "",
      "This command registers your current nickname as an alias of the",
      "NickServ account you are currently identified to.",
      "",
      "If your current nickname is already registered, provide that nick's",
      "password so NickServ can move it into the account you are using now.",
      "Only the nickname moves; access entries, channel registrations and",
      "other sessions only follow when the old account is left with no",
      "nicknames (a whole-account move).",
      "",
      "Syntax: \x02GROUP [current-nick-password]\x02",
      "",
      "Examples:",
      "    \x02/msg NickServ GROUP\x02",
      "    \x02/msg NickServ GROUP currentnickpassword\x02"
    ])
  end

  @spec send_ungroup_help(User.t()) :: :ok
  defp send_ungroup_help(user) do
    notify(user, [
      "Help for \x02UNGROUP\x02:",
      format_help("UNGROUP", [], "Removes your current nickname from the account you are identified to."),
      "",
      "This command separates your current nickname from the current",
      "NickServ account and turns it into its own account.",
      "",
      "You cannot use it on the primary nickname of the account.",
      "",
      "Syntax: \x02UNGROUP\x02",
      "",
      "Example:",
      "    \x02/msg NickServ UNGROUP\x02"
    ])
  end

  @spec send_listchans_help(User.t()) :: :ok
  defp send_listchans_help(user) do
    notify(user, [
      "Help for \x02LISTCHANS\x02:",
      format_help("LISTCHANS", [], "Lists registered channels where your account is founder or successor."),
      "",
      "This command lists channels where your NickServ account is the",
      "founder or configured successor.",
      "",
      "Syntax: \x02LISTCHANS\x02",
      "",
      "Example:",
      "    \x02/msg NickServ LISTCHANS\x02"
    ])
  end
end
