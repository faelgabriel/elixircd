defmodule ElixIRCd.Services.Nickserv.Help do
  @moduledoc """
  Module for the NickServ help command.
  """

  @behaviour ElixIRCd.Service

  require Logger

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
  defp send_help_for_command(user, "GHOST"), do: send_ghost_help(user)
  defp send_help_for_command(user, "REGAIN"), do: send_regain_help(user)
  defp send_help_for_command(user, "RELEASE"), do: send_release_help(user)
  defp send_help_for_command(user, "DROP"), do: send_drop_help(user)
  defp send_help_for_command(user, "INFO"), do: send_info_help(user)
  defp send_help_for_command(user, "SET"), do: send_set_help(user)
  defp send_help_for_command(user, "SET HIDEMAIL"), do: send_set_hidemail_help(user)
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
    min_password_length = Application.get_env(:elixircd, :services)[:nickserv][:min_password_length] || 6
    email_required? = Application.get_env(:elixircd, :services)[:nickserv][:email_required] || false
    wait_register_time = Application.get_env(:elixircd, :services)[:nickserv][:wait_register_time] || 0

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
      "nickname and then changes your nickname to it.",
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
      "REGAIN command, making it available for anyone to use.",
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

  @spec send_faq_help(User.t()) :: :ok
  defp send_faq_help(user) do
    unverified_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:unverified_expire_days] || 1
    wait_register_time = Application.get_env(:elixircd, :services)[:nickserv][:wait_register_time] || 0

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
      "A: If you have registered with an email address, you can",
      "   use the \x02SENDPASS\x02 command to get a reset link. Otherwise,",
      "   you need to contact a network administrator.",
      "",
      "Q: My nickname has expired. Can I get it back?",
      "A: If your nickname has expired due to inactivity, you can",
      "   simply register it again. Nicknames expire after",
      "   #{Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90} days of inactivity."
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
    nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90

    [
      "NickServ allows you to register and manage your nickname.",
      "Nicknames that remain unused for #{nick_expire_days} days may expire.",
      "",
      "The following commands are available:",
      "\x02REGISTER\x02     - Register a nickname",
      "\x02IDENTIFY\x02     - Identify to your nickname",
      "\x02VERIFY\x02       - Verify a registered nickname",
      "\x02GHOST\x02        - Kill a ghost session using your nickname",
      "\x02REGAIN\x02       - Regain your nickname from another user",
      "\x02RELEASE\x02      - Release a held nickname",
      "\x02DROP\x02         - Unregister a nickname",
      "\x02INFO\x02         - Display information about a nickname",
      "\x02SET\x02          - Set nickname options and information",
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
      "\x02HIDEMAIL\x02     - Hide your email address in INFO displays",
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
end
