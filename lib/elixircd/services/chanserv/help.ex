defmodule ElixIRCd.Services.Chanserv.Help do
  @moduledoc """
  Module for the ChanServ help command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

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
  defp send_help_for_command(user, "SET"), do: send_set_help(user)
  defp send_help_for_command(user, "SET GUARD"), do: send_set_guard_help(user)
  defp send_help_for_command(user, "SET KEEPTOPIC"), do: send_set_keeptopic_help(user)
  defp send_help_for_command(user, "SET PRIVATE"), do: send_set_private_help(user)
  defp send_help_for_command(user, "SET RESTRICTED"), do: send_set_restricted_help(user)
  defp send_help_for_command(user, "SET FANTASY"), do: send_set_fantasy_help(user)
  defp send_help_for_command(user, "SET DESCRIPTION"), do: send_set_description_help(user)
  defp send_help_for_command(user, "SET DESC"), do: send_set_description_help(user)
  defp send_help_for_command(user, "SET URL"), do: send_set_url_help(user)
  defp send_help_for_command(user, "SET EMAIL"), do: send_set_email_help(user)
  defp send_help_for_command(user, "SET ENTRYMSG"), do: send_set_entrymsg_help(user)
  defp send_help_for_command(user, "SET OPNOTICE"), do: send_set_opnotice_help(user)
  defp send_help_for_command(user, "SET PEACE"), do: send_set_peace_help(user)
  defp send_help_for_command(user, "SET SECURE"), do: send_set_secure_help(user)
  defp send_help_for_command(user, "SET TOPICLOCK"), do: send_set_topiclock_help(user)
  defp send_help_for_command(user, command), do: send_unknown_command_help(user, command)

  @spec send_general_help(User.t()) :: :ok
  defp send_general_help(user) do
    notify(user, [
      "\x02ChanServ\x02 allows you to register and maintain control",
      "of channels. ChanServ can often prevent malicious users from",
      "taking over channels by limiting who is allowed channel operator",
      "privileges.",
      " ",
      "\x02ChanServ commands\x02:",
      "\x02HELP         \x02- Displays this help message.",
      "\x02REGISTER     \x02- Register a channel.",
      "\x02SET          \x02- Set channel options and access levels.",
      " ",
      "For more information on a command, type:",
      "\x02/msg ChanServ HELP <command>\x02",
      " ",
      "For example: \x02/msg ChanServ HELP REGISTER\x02"
    ])
  end

  @spec send_register_help(User.t()) :: :ok
  defp send_register_help(user) do
    min_password_length = Application.get_env(:elixircd, :services)[:chanserv][:min_password_length] || 8

    notify(user, [
      "Help for \x02REGISTER\x02:",
      format_help(
        "REGISTER",
        ["<channel> <password>"],
        "Registers a channel with ChanServ."
      ),
      "",
      "Registers a channel with ChanServ and grants the registering",
      "user founder status. You must be identified with your NickServ",
      "account to register a channel.",
      " ",
      "The <password> is used for channel operations that require",
      "founder-level access. It must be at least #{min_password_length} characters long.",
      "Keep it secret and secure.",
      " ",
      "There is a limit on how many channels you can register.",
      "Some channel names may be reserved and cannot be registered.",
      " ",
      "Syntax: \x02REGISTER <channel> <password>\x02",
      " ",
      "Examples:",
      "    \x02/msg ChanServ REGISTER #mychannel mypassword\x02"
    ])
  end

  @spec send_set_help(User.t()) :: :ok
  defp send_set_help(user) do
    notify(user, [
      "Help for \x02SET\x02:",
      format_help(
        "SET",
        ["<channel> <option> [parameter]"],
        "Sets various channel options."
      ),
      "",
      "Allows the channel founder to configure various channel settings.",
      "Each option has its own set of valid parameters.",
      "Currently supported options are:",
      "",
      "\x02GUARD\x02        - Toggles whether ChanServ stays in the channel",
      "\x02KEEPTOPIC\x02    - Toggles whether the topic is preserved",
      "\x02PRIVATE\x02      - Hides channel from LIST command",
      "\x02RESTRICTED\x02   - Only allows identified users to join",
      "\x02FANTASY\x02      - Toggles support for !commands",
      "\x02DESCRIPTION\x02  - Sets channel description",
      "\x02URL\x02          - Sets channel website URL",
      "\x02EMAIL\x02        - Sets channel contact email",
      "\x02ENTRYMSG\x02     - Sets welcome message shown to new users",
      "\x02OPNOTICE\x02     - Toggles join notifications to ops",
      "\x02PEACE\x02        - Toggles protection against channel wars",
      "\x02SECURE\x02       - Toggles stricter security measures",
      "\x02TOPICLOCK\x02    - Controls who can change the channel topic",
      "",
      "For detailed help on each option, type:",
      "\x02/msg ChanServ HELP SET <option>\x02",
      "",
      "Syntax: \x02SET <channel> <option> [parameter]\x02",
      "",
      "Examples:",
      "    \x02/msg ChanServ SET #mychannel GUARD ON\x02",
      "    \x02/msg ChanServ SET #mychannel PRIVATE OFF\x02"
    ])
  end

  @spec send_set_guard_help(User.t()) :: :ok
  defp send_set_guard_help(user) do
    notify(user, [
      "Help for \x02SET GUARD\x02:",
      format_help(
        "SET GUARD",
        ["<channel> {ON|OFF}"],
        "Toggles ChanServ's presence in the channel."
      ),
      "",
      "When set to ON, ChanServ will join and remain in the channel.",
      "This helps prevent takeovers when the channel becomes empty",
      "and allows the use of fantasy commands (!op, !deop, etc.)",
      "if FANTASY is also enabled.",
      "",
      "When set to OFF, ChanServ will not join the channel.",
      "",
      "Syntax: \x02SET <channel> GUARD {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg ChanServ SET #mychannel GUARD ON\x02"
    ])
  end

  @spec send_set_keeptopic_help(User.t()) :: :ok
  defp send_set_keeptopic_help(user) do
    notify(user, [
      "Help for \x02SET KEEPTOPIC\x02:",
      format_help(
        "SET KEEPTOPIC",
        ["<channel> {ON|OFF}"],
        "Toggles topic preservation."
      ),
      "",
      "When set to ON, ChanServ will remember the channel topic",
      "even when the channel becomes empty, and will restore it",
      "when the channel is recreated or when new users join.",
      "",
      "When set to OFF, the topic will not be preserved when the",
      "channel becomes empty.",
      "",
      "Syntax: \x02SET <channel> KEEPTOPIC {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg ChanServ SET #mychannel KEEPTOPIC ON\x02"
    ])
  end

  @spec send_set_private_help(User.t()) :: :ok
  defp send_set_private_help(user) do
    notify(user, [
      "Help for \x02SET PRIVATE\x02:",
      format_help(
        "SET PRIVATE",
        ["<channel> {ON|OFF}"],
        "Toggles channel privacy."
      ),
      "",
      "When set to ON, the channel will not appear in the server's",
      "channel listing when users use the /LIST command.",
      "This helps maintain privacy for channels that want to remain",
      "hidden from casual browsers.",
      "",
      "When set to OFF, the channel will appear normally in /LIST.",
      "",
      "Syntax: \x02SET <channel> PRIVATE {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg ChanServ SET #mychannel PRIVATE ON\x02"
    ])
  end

  @spec send_set_restricted_help(User.t()) :: :ok
  defp send_set_restricted_help(user) do
    notify(user, [
      "Help for \x02SET RESTRICTED\x02:",
      format_help(
        "SET RESTRICTED",
        ["<channel> {ON|OFF}"],
        "Toggles restricted access."
      ),
      "",
      "When set to ON, only users who are identified with NickServ",
      "will be allowed to join the channel. This helps ensure that",
      "all users in the channel have registered identities.",
      "",
      "When set to OFF, anyone can join the channel regardless of",
      "whether they are identified with NickServ or not.",
      "",
      "Syntax: \x02SET <channel> RESTRICTED {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg ChanServ SET #mychannel RESTRICTED ON\x02"
    ])
  end

  @spec send_set_fantasy_help(User.t()) :: :ok
  defp send_set_fantasy_help(user) do
    notify(user, [
      "Help for \x02SET FANTASY\x02:",
      format_help(
        "SET FANTASY",
        ["<channel> {ON|OFF}"],
        "Toggles fantasy commands."
      ),
      "",
      "When set to ON, users in the channel can use special commands",
      "prefixed with ! to perform actions through ChanServ without",
      "messaging it directly. Examples include !op, !deop, !voice.",
      "",
      "Note that GUARD must also be set to ON for fantasy commands",
      "to work, as ChanServ needs to be in the channel to see them.",
      "",
      "When set to OFF, fantasy commands will not work in the channel.",
      "",
      "Syntax: \x02SET <channel> FANTASY {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg ChanServ SET #mychannel FANTASY ON\x02"
    ])
  end

  @spec send_set_description_help(User.t()) :: :ok
  defp send_set_description_help(user) do
    notify(user, [
      "Help for \x02SET DESCRIPTION\x02:",
      format_help(
        "SET DESCRIPTION",
        ["<channel> [text]"],
        "Sets the channel description."
      ),
      "",
      "Sets a description for the channel that will be displayed when",
      "users request information about the channel. If no text is",
      "provided, the current description will be displayed.",
      "",
      "To clear the description, set it to an empty string.",
      "",
      "Syntax: \x02SET <channel> DESCRIPTION [text]\x02",
      "",
      "Examples:",
      "    \x02/msg ChanServ SET #mychannel DESCRIPTION A channel for discussing topics\x02",
      "    \x02/msg ChanServ SET #mychannel DESCRIPTION\x02 (to view current)",
      "    \x02/msg ChanServ SET #mychannel DESCRIPTION \x02 (to clear)"
    ])
  end

  @spec send_set_url_help(User.t()) :: :ok
  defp send_set_url_help(user) do
    notify(user, [
      "Help for \x02SET URL\x02:",
      format_help(
        "SET URL",
        ["<channel> [url|OFF]"],
        "Sets the channel website URL."
      ),
      "",
      "Sets a URL for the channel's website that will be displayed when",
      "users request information about the channel. If no URL is",
      "provided, the current URL will be displayed.",
      "",
      "To clear the URL, use the OFF parameter.",
      "",
      "Syntax: \x02SET <channel> URL [url|OFF]\x02",
      "",
      "Examples:",
      "    \x02/msg ChanServ SET #mychannel URL https://example.com\x02",
      "    \x02/msg ChanServ SET #mychannel URL\x02 (to view current)",
      "    \x02/msg ChanServ SET #mychannel URL OFF\x02 (to clear)"
    ])
  end

  @spec send_set_email_help(User.t()) :: :ok
  defp send_set_email_help(user) do
    notify(user, [
      "Help for \x02SET EMAIL\x02:",
      format_help(
        "SET EMAIL",
        ["<channel> [email|OFF]"],
        "Sets the channel contact email."
      ),
      "",
      "Sets a contact email address for the channel that will be displayed",
      "when users request information about the channel. If no email is",
      "provided, the current email will be displayed.",
      "",
      "To clear the email, use the OFF parameter.",
      "",
      "Syntax: \x02SET <channel> EMAIL [email|OFF]\x02",
      "",
      "Examples:",
      "    \x02/msg ChanServ SET #mychannel EMAIL contact@example.com\x02",
      "    \x02/msg ChanServ SET #mychannel EMAIL\x02 (to view current)",
      "    \x02/msg ChanServ SET #mychannel EMAIL OFF\x02 (to clear)"
    ])
  end

  @spec send_set_entrymsg_help(User.t()) :: :ok
  defp send_set_entrymsg_help(user) do
    notify(user, [
      "Help for \x02SET ENTRYMSG\x02:",
      format_help(
        "SET ENTRYMSG",
        ["<channel> [message|OFF]"],
        "Sets the channel welcome message."
      ),
      "",
      "Sets a welcome message that will be sent to users when they join",
      "the channel. If no message is provided, the current message will",
      "be displayed.",
      "",
      "To clear the entry message, use the OFF parameter or set it to an empty string.",
      "",
      "Syntax: \x02SET <channel> ENTRYMSG [message|OFF]\x02",
      "",
      "Examples:",
      "    \x02/msg ChanServ SET #mychannel ENTRYMSG Welcome to our channel!\x02",
      "    \x02/msg ChanServ SET #mychannel ENTRYMSG\x02 (to view current)",
      "    \x02/msg ChanServ SET #mychannel ENTRYMSG OFF\x02 (to clear)"
    ])
  end

  @spec send_set_opnotice_help(User.t()) :: :ok
  defp send_set_opnotice_help(user) do
    notify(user, [
      "Help for \x02SET OPNOTICE\x02:",
      format_help(
        "SET OPNOTICE",
        ["<channel> {ON|OFF}"],
        "Toggles channel operator notifications."
      ),
      "",
      "When set to ON, ChanServ will notify channel operators when",
      "users join the channel. This can be useful for monitoring",
      "channel activity and maintaining security.",
      "",
      "When set to OFF, no notifications will be sent to operators.",
      "",
      "Syntax: \x02SET <channel> OPNOTICE {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg ChanServ SET #mychannel OPNOTICE ON\x02"
    ])
  end

  @spec send_set_peace_help(User.t()) :: :ok
  defp send_set_peace_help(user) do
    notify(user, [
      "Help for \x02SET PEACE\x02:",
      format_help(
        "SET PEACE",
        ["<channel> {ON|OFF}"],
        "Toggles protection against channel wars."
      ),
      "",
      "When set to ON, ChanServ will prevent channel operators from",
      "kicking or banning other channel operators. This helps prevent",
      "destructive 'op wars' where operators kick and ban each other.",
      "",
      "When set to OFF, operators can kick or ban other operators",
      "according to normal channel privileges.",
      "",
      "Syntax: \x02SET <channel> PEACE {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg ChanServ SET #mychannel PEACE ON\x02"
    ])
  end

  @spec send_set_secure_help(User.t()) :: :ok
  defp send_set_secure_help(user) do
    notify(user, [
      "Help for \x02SET SECURE\x02:",
      format_help(
        "SET SECURE",
        ["<channel> {ON|OFF}"],
        "Toggles stricter security measures."
      ),
      "",
      "When set to ON, ChanServ enforces stricter security measures:",
      "- Only identified users can be given channel privileges",
      "- Channel privileges are checked more frequently",
      "- Access control lists are enforced more strictly",
      "",
      "When set to OFF, normal security measures apply.",
      "",
      "Syntax: \x02SET <channel> SECURE {ON|OFF}\x02",
      "",
      "Example:",
      "    \x02/msg ChanServ SET #mychannel SECURE ON\x02"
    ])
  end

  @spec send_set_topiclock_help(User.t()) :: :ok
  defp send_set_topiclock_help(user) do
    notify(user, [
      "Help for \x02SET TOPICLOCK\x02:",
      format_help(
        "SET TOPICLOCK",
        ["<channel> {ON|OFF}"],
        "Controls who can change the channel topic."
      ),
      "",
      "SET TOPICLOCK causes ChanServ to revert topic changes by users",
      "without the +t flag. Topic changes during netsplits or services",
      "outages will always be reverted.",
      "",
      "\x02ON\x02  - Only users with the +t flag can change the topic",
      "\x02OFF\x02 - Anyone can change the topic if channel mode allows it",
      "",
      "If no parameter is provided, shows the current TOPICLOCK setting.",
      "",
      "Syntax: \x02SET <channel> TOPICLOCK {ON|OFF}\x02",
      "",
      "Examples:",
      "    \x02/msg ChanServ SET #mychannel TOPICLOCK ON\x02",
      "    \x02/msg ChanServ SET #mychannel TOPICLOCK OFF\x02"
    ])
  end

  @spec send_unknown_command_help(User.t(), String.t()) :: :ok
  defp send_unknown_command_help(user, topic) do
    notify(user, [
      "\x02#{topic}\x02 is not a valid command or help topic.",
      "For a list of help topics, type \x02/msg ChanServ HELP\x02"
    ])
  end

  @spec format_help(String.t(), [String.t()], String.t()) :: String.t()
  defp format_help(command, syntax, description) do
    syntax_str = Enum.join(syntax, " or ")
    "\x02#{command} #{syntax_str}\x02 - #{description}"
  end
end
