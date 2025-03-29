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
    command = Enum.at(rest_params, 0)

    case command do
      nil -> send_general_help(user)
      "REGISTER" -> send_register_help(user)
      "VERIFY" -> send_verify_help(user)
      "FAQ" -> send_faq_help(user)
      "POLICY" -> send_policy_help(user)
      _ -> send_unknown_command_help(user, command)
    end

    :ok
  end

  @spec send_general_help(User.t()) :: :ok
  defp send_general_help(user) do
    send_notice(user, "NickServ help:")
    Enum.each(general_help(), &send_notice(user, &1))
    send_notice(user, "For more information on a command, type /msg NickServ HELP <command>")
  end

  @spec send_register_help(User.t()) :: :ok
  defp send_register_help(user) do
    max_nicks = Application.get_env(:elixircd, :services)[:nickserv][:max_nicks_per_user] || 3
    min_password_length = Application.get_env(:elixircd, :services)[:nickserv][:min_password_length] || 6
    email_required? = Application.get_env(:elixircd, :services)[:nickserv][:email_required] || false

    send_notice(user, "Help for REGISTER:")

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
    send_notice(user, "You may register up to #{max_nicks} nicknames per account.")
    send_notice(user, "")
    send_notice(user, "Syntax: REGISTER <password> #{email_required_format(email_required?)}")
    send_notice(user, "")
    send_notice(user, "Example:")
    send_notice(user, "    /msg NickServ REGISTER mypassword user@example.com")
  end

  @spec send_verify_help(User.t()) :: :ok
  defp send_verify_help(user) do
    send_notice(user, "Help for VERIFY:")
    send_notice(user, format_help("VERIFY", ["nickname code"], "Verifies a registered nickname."))
    send_notice(user, "")
    send_notice(user, "This command completes the registration process for your nickname.")
    send_notice(user, "You will receive a verification code when you register.")
    send_notice(user, "")
    send_notice(user, "Syntax: VERIFY nickname code")
    send_notice(user, "")
    send_notice(user, "Example:")
    send_notice(user, "    /msg NickServ VERIFY mynick abc123def456")
  end

  @spec send_faq_help(User.t()) :: :ok
  defp send_faq_help(user) do
    send_notice(user, "Help for FAQ:")
    send_notice(user, "")
    send_notice(user, "Frequently Asked Questions:")
    send_notice(user, "")
    send_notice(user, "Q: Why should I register my nickname?")
    send_notice(user, "A: Registering your nickname helps you maintain a unique")
    send_notice(user, "   identity on the network and prevents others from using it.")
    send_notice(user, "")
    send_notice(user, "Q: I forgot my password. What can I do?")
    send_notice(user, "A: If you have registered with an email address, you can")
    send_notice(user, "   use the SENDPASS command to get a reset link. Otherwise,")
    send_notice(user, "   you need to contact a network administrator.")
    send_notice(user, "")
    send_notice(user, "Q: My nickname has expired. Can I get it back?")
    send_notice(user, "A: If your nickname has expired due to inactivity, you can")
    send_notice(user, "   simply register it again. Nicknames expire after")

    send_notice(
      user,
      "   #{Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90} days of inactivity."
    )

    send_notice(user, "")
    send_notice(user, "Q: What does it mean to \"identify\"?")
    send_notice(user, "A: Identifying means proving to NickServ that you are the")
    send_notice(user, "   owner of a registered nickname by providing the correct")
    send_notice(user, "   password with the IDENTIFY command.")
    send_notice(user, "")
    send_notice(user, "Q: Can I register multiple nicknames?")
    send_notice(user, "A: Yes, you can register up to")

    send_notice(
      user,
      "   #{Application.get_env(:elixircd, :services)[:nickserv][:max_nicks_per_user] || 3} nicknames per account."
    )

    send_notice(user, "   Use the GROUP command to add nicknames to your account.")
  end

  @spec send_policy_help(User.t()) :: :ok
  defp send_policy_help(user) do
    send_notice(user, "Help for POLICY:")
    send_notice(user, "")
    send_notice(user, "Network Policy for Nickname Registration:")
    send_notice(user, "")
    send_notice(user, "By registering a nickname on this network, you agree to abide")
    send_notice(user, "by the following terms:")
    send_notice(user, "")
    send_notice(user, "1. Nicknames are allocated on a first-come, first-served basis.")
    send_notice(user, "2. Network administrators reserve the right to remove or reclaim")
    send_notice(user, "   nicknames that violate network policies or are inactive.")
    send_notice(user, "3. Harassment, hate speech, or illegal activities conducted under")
    send_notice(user, "   registered nicknames may result in the nickname being removed.")
    send_notice(user, "4. If you provide an email address, it will only be used for account")
    send_notice(user, "   verification and password recovery purposes.")

    send_notice(
      user,
      "5. Nicknames inactive for #{Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90} days may be"
    )

    send_notice(user, "   automatically expired and become available for registration again.")
  end

  @spec send_unknown_command_help(User.t(), String.t()) :: :ok
  defp send_unknown_command_help(user, command) do
    send_notice(user, "Help for #{command} is not available.")
    send_notice(user, "For a list of available commands, type /msg NickServ HELP")
  end

  @spec general_help() :: [String.t()]
  defp general_help do
    nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90

    [
      "NickServ allows you to register and manage your nickname.",
      "Nicknames that remain unused for #{nick_expire_days} days may expire.",
      "",
      "The following commands are available:",
      "REGISTER     - Register a nickname",
      "",
      "For more information on a command, type /msg NickServ HELP <command>"
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec format_help(String.t(), [String.t()], String.t()) :: String.t()
  defp format_help(command, syntax, description) do
    syntax_str = Enum.join(syntax, " or ")
    "#{command} #{syntax_str} - #{description}"
  end
end
