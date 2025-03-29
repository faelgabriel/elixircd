defmodule ElixIRCd.Services.Nickserv do
  @moduledoc """
  Module for handling incoming NickServ commands.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [
    format_help: 3,
    general_help: 0,
    send_notice: 2,
    can_register_more_nicks?: 1
  ]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["REGISTER", password | rest_params]) do
    email = Enum.at(rest_params, 0)

    # Get configuration
    min_password_length = Application.get_env(:elixircd, :services)[:nickserv][:min_password_length] || 6
    email_required = Application.get_env(:elixircd, :services)[:nickserv][:email_required] || false
    max_nicks = Application.get_env(:elixircd, :services)[:nickserv][:max_nicks_per_user] || 3

    # Verification moved from repository to here
    case RegisteredNicks.get_by_nickname(user.nick) do
      {:ok, _} ->
        send_notice(
          user,
          "This nickname is already registered. If this is your nickname, type /msg NickServ IDENTIFY password."
        )

      {:error, _} ->
        cond do
          # Check if password is too short
          String.length(password) < min_password_length ->
            send_notice(user, "The password is too short. Please use at least #{min_password_length} characters.")

          # Check if email is required but not provided
          email_required && (is_nil(email) || String.trim(email) == "") ->
            send_notice(user, "You must specify an email address to register a nickname.")

          # Check if user has reached the maximum number of registered nicknames
          !can_register_more_nicks?(user_mask(user)) ->
            send_notice(user, "You have reached the maximum number of registered nicknames (#{max_nicks}).")
            send_notice(user, "Please drop one of your existing nicknames before registering a new one.")

          # All validation passed, proceed with registration
          true ->
            register_nickname(user, password, email)
        end
    end

    :ok
  end

  # def handle(user, ["IDENTIFY", password]) do
  #   # Identifies user with their registered nickname using password
  #   :ok
  # end

  # def handle(user, ["VERIFY", nickname, code]) do
  #   # Verifies a registered nickname using the verification code
  #   :ok
  # end

  # def handle(user, ["SET", "PASSWORD", new_password]) do
  #   # Changes the password for the user's registered nickname
  #   :ok
  # end

  # def handle(user, ["SET", "EMAIL", new_email]) do
  #   # Changes the email associated with the user's registered nickname
  #   :ok
  # end

  # def handle(user, ["DROP" | rest_params]) do
  #   # nickname is optional (defaults to current nick)
  #   nickname = Enum.at(rest_params, 0)
  #   :ok
  # end

  # def handle(user, ["GHOST", nickname, password]) do
  #   # Disconnects a "ghost" session using the registered nickname
  #   :ok
  # end

  # def handle(user, ["RECOVER", nickname, password]) do
  #   # Recovers a nickname that's being used by someone else
  #   :ok
  # end

  # def handle(user, ["RELEASE", nickname | rest_params]) do
  #   # password is optional if user is already identified
  #   password = Enum.at(rest_params, 0)
  #   :ok
  # end

  # def handle(user, ["GROUP", target_nick, password]) do
  #   # Groups current nickname with an existing account
  #   :ok
  # end

  # def handle(user, ["UNGROUP" | rest_params]) do
  #   # nickname is optional (defaults to current nick)
  #   nickname = Enum.at(rest_params, 0)
  #   :ok
  # end

  # def handle(user, ["LISTCHANS"]) do
  #   # Lists channels where the user has registered access
  #   :ok
  # end

  # def handle(user, ["INFO" | rest_params]) do
  #   # nickname is optional (defaults to current nick)
  #   nickname = Enum.at(rest_params, 0)
  #   :ok
  # end

  # def handle(user, ["STATUS" | rest_params]) do
  #   # nickname is optional (defaults to current nick)
  #   nickname = Enum.at(rest_params, 0)
  #   :ok
  # end

  # def handle(user, ["ACCESS", "ADD", host]) do
  #   # Adds a host to the user's access list
  #   :ok
  # end

  # def handle(user, ["ACCESS", "DEL", host]) do
  #   # Removes a host from the user's access list
  #   :ok
  # end

  # def handle(user, ["ACCESS", "LIST"]) do
  #   # Lists all hosts in the user's access list
  #   :ok
  # end

  # def handle(user, ["SENDPASS", nickname]) do
  #   # Sends password reset instructions to registered email
  #   :ok
  # end

  def handle(user, ["HELP" | rest_params]) do
    command = Enum.at(rest_params, 0)

    case command do
      nil ->
        # Send general help
        Enum.each(general_help(), fn help_line ->
          send_notice(user, help_line)
        end)

      "REGISTER" ->
        max_nicks = Application.get_env(:elixircd, :services)[:nickserv][:max_nicks_per_user] || 3

        send_notice(
          user,
          format_help(
            "REGISTER",
            ["password [email]"],
            "Registers your current nickname with NickServ."
          )
        )

        send_notice(user, "This will register your current nickname with the specified password.")
        send_notice(user, "The email address is optional unless configured otherwise.")
        send_notice(user, "You may register up to #{max_nicks} nicknames per account.")
        send_notice(user, "Example: /msg NickServ REGISTER mypassword user@example.com")

      "VERIFY" ->
        send_notice(
          user,
          format_help(
            "VERIFY",
            ["nickname code"],
            "Verifies a registered nickname using the verification code."
          )
        )

        send_notice(user, "This command completes the registration process for your nickname.")
        send_notice(user, "You will receive a verification code when you register a nickname.")
        send_notice(user, "Example: /msg NickServ VERIFY mynick abc123def456")

      # Add help for other commands as they are implemented
      _ ->
        send_notice(user, "No help available for command #{command}.")
        send_notice(user, "For a list of commands, type /msg NickServ HELP")
    end

    :ok
  end

  # Catch-all for unrecognized commands
  def handle(user, [command | _]) do
    send_notice(user, "Unknown command: #{command}")
    send_notice(user, "For a list of commands, type /msg NickServ HELP")
    :ok
  end

  # Handle empty command
  def handle(user, []) do
    send_notice(user, "NickServ allows you to register and manage your nickname.")
    send_notice(user, "For a list of commands, type /msg NickServ HELP")
    :ok
  end

  # Private helper functions

  @spec register_nickname(User.t(), String.t(), String.t() | nil) :: :ok
  defp register_nickname(user, password, email) do
    # Hash password using Pbkdf2
    password_hash = Pbkdf2.hash_pwd_salt(password)

    # Generate a random verification code
    verify_code = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    # Register the nickname
    RegisteredNicks.create(%{
      nickname: user.nick,
      password_hash: password_hash,
      email: email,
      registered_by: user_mask(user),
      verify_code: verify_code
    })

    if is_nil(email) do
      send_notice(user, "Nickname #{user.nick} registered successfully.")
    else
      send_notice(user, "Nickname #{user.nick} registered successfully with email address #{email}.")
    end

    # Optional welcome message
    send_notice(user, "Thank you for registering your nickname!")
    send_notice(user, "Your verification code is: #{verify_code}")
    send_notice(user, "Please verify your nickname using /msg NickServ VERIFY #{user.nick} #{verify_code}")
    send_notice(user, "You can also identify to services using /msg NickServ IDENTIFY password")
    send_notice(user, "For help on using NickServ commands, type /msg NickServ HELP")

    # Log successful registration
    Logger.info("Nickname registered: #{user.nick} by #{user_mask(user)}")
  end
end
