defmodule ElixIRCd.Services.Nickserv.Help do
  @moduledoc """
  Module for the NickServ help command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [send_notice: 2, email_required_format: 1]

  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["HELP" | rest_params]) do
    normalized_command =
      (Enum.at(rest_params, 0) || "")
      |> String.upcase()

    case normalized_command do
      "" -> send_general_help(user)
      "REGISTER" -> send_register_help(user)
      "VERIFY" -> send_verify_help(user)
      "IDENTIFY" -> send_identify_help(user)
      "GHOST" -> send_ghost_help(user)
      "REGAIN" -> send_regain_help(user)
      "RELEASE" -> send_release_help(user)
      "DROP" -> send_drop_help(user)
      "INFO" -> send_info_help(user)
      "FAQ" -> send_faq_help(user)
      _ -> send_unknown_command_help(user, normalized_command)
    end

    :ok
  end

  @spec send_general_help(User.t()) :: :ok
  defp send_general_help(user) do
    send_notice(user, "NickServ help:")
    Enum.each(general_help(), &send_notice(user, &1))
    send_notice(user, "For more information on a command, type \x02/msg NickServ HELP <command>\x02")
  end

  @spec send_register_help(User.t()) :: :ok
  defp send_register_help(user) do
    min_password_length = Application.get_env(:elixircd, :services)[:nickserv][:min_password_length] || 6
    email_required? = Application.get_env(:elixircd, :services)[:nickserv][:email_required] || false
    waitreg_time = Application.get_env(:elixircd, :services)[:nickserv][:waitreg_time] || 0

    send_notice(user, "Help for \x02REGISTER\x02:")

    send_notice(
      user,
      format_help(
        "REGISTER",
        ["<password> #{email_required_format(email_required?)}"],
        "Registers your current nickname."
      )
    )

    send_notice(user, "")
    send_notice(user, "This will register your current nickname with NickServ.")
    send_notice(user, "This will allow you to assert some form of identity on the network")
    send_notice(user, "and to be added to access lists. Furthermore, NickServ will warn")
    send_notice(user, "users using your nick without identifying and allow you to kill ghosts.")

    if waitreg_time > 0 do
      send_notice(user, "")
      send_notice(user, "You must be connected for at least #{waitreg_time} seconds")
      send_notice(user, "before you can register your nickname.")
    end

    if email_required? do
      send_notice(user, "")
      send_notice(user, "This server REQUIRES an email address for registration.")
      send_notice(user, "You have to confirm the email address. To do this, follow")
      send_notice(user, "the instructions in the message sent to the email address.")
    else
      send_notice(user, "")
      send_notice(user, "An email address is optional but recommended. If provided,")
      send_notice(user, "you can use it to reset your password if you forget it.")
    end

    send_notice(user, "")
    send_notice(user, "Your password must be at least #{min_password_length} characters long.")
    send_notice(user, "Please write down or memorize your password! You will need it later")
    send_notice(user, "to change settings. The password is case-sensitive.")
    send_notice(user, "")
    send_notice(user, "Syntax: \x02REGISTER <password> #{email_required_format(email_required?)}\x02")
    send_notice(user, "")
    send_notice(user, "Example:")
    send_notice(user, "    \x02/msg NickServ REGISTER mypassword user@example.com\x02")
  end

  @spec send_verify_help(User.t()) :: :ok
  defp send_verify_help(user) do
    send_notice(user, "Help for \x02VERIFY\x02:")
    send_notice(user, format_help("VERIFY", ["nickname code"], "Verifies a registered nickname."))
    send_notice(user, "")
    send_notice(user, "This command completes the registration process for your nickname.")
    send_notice(user, "You will receive a verification code when you register.")
    send_notice(user, "")
    send_notice(user, "Syntax: \x02VERIFY nickname code\x02")
    send_notice(user, "")
    send_notice(user, "Example:")
    send_notice(user, "    \x02/msg NickServ VERIFY mynick abc123def456\x02")
  end

  @spec send_identify_help(User.t()) :: :ok
  defp send_identify_help(user) do
    send_notice(user, "Help for \x02IDENTIFY\x02:")

    send_notice(
      user,
      format_help(
        "IDENTIFY",
        ["[nickname] <password>"],
        "Identifies you with your account."
      )
    )

    send_notice(user, "")
    send_notice(user, "This will identify your current session to NickServ, giving you")
    send_notice(user, "access to all privileges granted to your account.")

    send_notice(user, "")
    send_notice(user, "If you specify a nickname, you will identify to that account")
    send_notice(user, "instead of the account matching your current nickname.")

    send_notice(user, "")
    send_notice(user, "When identifying to a nickname that doesn't match your current nick,")
    send_notice(user, "your current nick will be recognized as belonging to that account.")

    send_notice(user, "")
    send_notice(user, "Syntax: \x02IDENTIFY [nickname] <password>\x02")
    send_notice(user, "")
    send_notice(user, "Examples:")
    send_notice(user, "    \x02/msg NickServ IDENTIFY mypassword\x02")
    send_notice(user, "    \x02/msg NickServ IDENTIFY MyNick mypassword\x02")
  end

  @spec send_ghost_help(User.t()) :: :ok
  defp send_ghost_help(user) do
    send_notice(user, "Help for \x02GHOST\x02:")

    send_notice(
      user,
      format_help(
        "GHOST",
        ["<nick> [password]"],
        "Kills a ghost session using your nickname."
      )
    )

    send_notice(user, "")
    send_notice(user, "The GHOST command allows you to disconnect an old or")
    send_notice(user, "unauthorized session that's using your registered nickname.")
    send_notice(user, "")
    send_notice(user, "If you're identified to a nickname, you can use this command")
    send_notice(user, "without a password to ghost anyone using that nickname.")
    send_notice(user, "")
    send_notice(user, "If you're not identified, you'll need to provide the correct")
    send_notice(user, "password for the nickname you're trying to ghost.")
    send_notice(user, "")
    send_notice(user, "Syntax: \x02GHOST <nick> [password]\x02")
    send_notice(user, "")
    send_notice(user, "Example:")
    send_notice(user, "    \x02/msg NickServ GHOST MyNick MyPassword\x02")
  end

  @spec send_regain_help(User.t()) :: :ok
  defp send_regain_help(user) do
    send_notice(user, "Help for \x02REGAIN\x02:")

    send_notice(
      user,
      format_help(
        "REGAIN",
        ["<nickname> <password>"],
        "Regains a nickname you own and are not currently using."
      )
    )

    send_notice(user, "")
    send_notice(user, "This command disconnects another user who is using your")
    send_notice(user, "nickname and then changes your nickname to it.")
    send_notice(user, "")
    send_notice(user, "If the nickname is not currently in use, it simply changes")
    send_notice(user, "your nickname. If you are already identified to the nickname,")
    send_notice(user, "you don't need to specify a password.")
    send_notice(user, "")
    send_notice(user, "Syntax: \x02REGAIN <nickname> <password>\x02")
    send_notice(user, "")
    send_notice(user, "Example:")
    send_notice(user, "    \x02/msg NickServ REGAIN MyNick MyPassword\x02")
  end

  @spec send_release_help(User.t()) :: :ok
  defp send_release_help(user) do
    send_notice(user, "Help for \x02RELEASE\x02:")

    send_notice(
      user,
      format_help(
        "RELEASE",
        ["<nickname> <password>"],
        "Releases a held nickname."
      )
    )

    send_notice(user, "")
    send_notice(user, "This command releases a nickname that was reserved by the")
    send_notice(user, "REGAIN command, making it available for anyone to use.")
    send_notice(user, "")
    send_notice(user, "You must be identified to the nickname or provide its")
    send_notice(user, "correct password to release it.")
    send_notice(user, "")
    send_notice(user, "Syntax: \x02RELEASE <nickname> <password>\x02")
    send_notice(user, "")
    send_notice(user, "Example:")
    send_notice(user, "    \x02/msg NickServ RELEASE MyNick MyPassword\x02")
  end

  @spec send_drop_help(User.t()) :: :ok
  defp send_drop_help(user) do
    send_notice(user, "Help for \x02DROP\x02:")

    send_notice(
      user,
      format_help(
        "DROP",
        ["<nickname> [password]"],
        "Unregisters a nickname."
      )
    )

    send_notice(user, "")
    send_notice(user, "This command deletes the registration for a nickname,")
    send_notice(user, "removing it and all related access, making it available")
    send_notice(user, "for registration by anyone again.")
    send_notice(user, "")
    send_notice(user, "If you are identified to the nickname you want to drop,")
    send_notice(user, "you don't need to provide a password. Otherwise, you must")
    send_notice(user, "provide the nickname's password.")
    send_notice(user, "")
    send_notice(user, "If you don't specify a nickname, your current nick will be dropped.")
    send_notice(user, "")
    send_notice(user, "Syntax: \x02DROP <nickname> [password]\x02")
    send_notice(user, "")
    send_notice(user, "Examples:")
    send_notice(user, "    \x02/msg NickServ DROP\x02")
    send_notice(user, "    \x02/msg NickServ DROP MyNick\x02")
    send_notice(user, "    \x02/msg NickServ DROP MyOtherNick MyPassword\x02")
  end

  @spec send_info_help(User.t()) :: :ok
  defp send_info_help(user) do
    send_notice(user, "Help for \x02INFO\x02:")

    send_notice(
      user,
      format_help(
        "INFO",
        ["[nickname]"],
        "Displays information about a registered nickname."
      )
    )

    send_notice(user, "")
    send_notice(user, "This command displays information about a registered nickname,")
    send_notice(user, "such as its registration date, last seen time, and options.")
    send_notice(user, "")
    send_notice(user, "If you don't specify a nickname, information about your")
    send_notice(user, "current nickname will be displayed.")
    send_notice(user, "")
    send_notice(user, "If the server has privacy features enabled, some information")
    send_notice(user, "may be hidden unless you are identified to the nickname or")
    send_notice(user, "are an IRC operator.")
    send_notice(user, "")
    send_notice(user, "Syntax: \x02INFO [nickname]\x02")
    send_notice(user, "")
    send_notice(user, "Examples:")
    send_notice(user, "    \x02/msg NickServ INFO\x02")
    send_notice(user, "    \x02/msg NickServ INFO SomeNick\x02")
  end

  @spec send_faq_help(User.t()) :: :ok
  defp send_faq_help(user) do
    send_notice(user, "Help for \x02FAQ\x02:")
    send_notice(user, "")
    send_notice(user, "Frequently Asked Questions:")
    send_notice(user, "")
    send_notice(user, "Q: Why should I register my nickname?")
    send_notice(user, "A: Registering your nickname helps you maintain a unique")
    send_notice(user, "   identity on the network and prevents others from using it.")
    send_notice(user, "")
    send_notice(user, "Q: I forgot my password. What can I do?")
    send_notice(user, "A: If you have registered with an email address, you can")
    send_notice(user, "   use the \x02SENDPASS\x02 command to get a reset link. Otherwise,")
    send_notice(user, "   you need to contact a network administrator.")
    send_notice(user, "")
    send_notice(user, "Q: My nickname has expired. Can I get it back?")
    send_notice(user, "A: If your nickname has expired due to inactivity, you can")
    send_notice(user, "   simply register it again. Nicknames expire after")

    send_notice(
      user,
      "   #{Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90} days of inactivity."
    )

    # Add information about unverified nickname expiration if enabled
    unverified_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:unverified_expire_days] || 1

    if unverified_expire_days > 0 do
      send_notice(user, "")
      send_notice(user, "Q: How long do I have to verify my nickname after registration?")

      send_notice(
        user,
        "A: You must verify your nickname within #{unverified_expire_days} #{pluralize_days(unverified_expire_days)}"
      )

      send_notice(user, "   after registration or it will expire and you'll need to register again.")
    end

    send_notice(user, "")
    send_notice(user, "Q: What does it mean to \x02identify\x02?")
    send_notice(user, "A: Identifying means proving to NickServ that you are the")
    send_notice(user, "   owner of a registered nickname by providing the correct")
    send_notice(user, "   password with the \x02IDENTIFY\x02 command.")

    waitreg_time = Application.get_env(:elixircd, :services)[:nickserv][:waitreg_time] || 0

    if waitreg_time > 0 do
      send_notice(user, "")
      send_notice(user, "Q: Why can't I register my nickname immediately after connecting?")
      send_notice(user, "A: This server requires you to be connected for at least")
      send_notice(user, "   #{waitreg_time} seconds before you can register a nickname.")
      send_notice(user, "   This is to prevent abuse of the registration system.")
    end
  end

  @spec send_unknown_command_help(User.t(), String.t()) :: :ok
  defp send_unknown_command_help(user, command) do
    send_notice(user, "Help for \x02#{command}\x02 is not available.")
    send_notice(user, "For a list of available commands, type \x02/msg NickServ HELP\x02")
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
end
