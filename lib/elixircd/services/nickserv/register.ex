defmodule ElixIRCd.Services.Nickserv.Register do
  @moduledoc """
  Module for the NickServ register command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Mailer, only: [send_verification_email: 3]
  import ElixIRCd.Utils.Nickserv, only: [send_notice: 2, email_required_format: 1]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["REGISTER", password | rest_params]) do
    email = Enum.at(rest_params, 0)

    min_password_length = Application.get_env(:elixircd, :services)[:nickserv][:min_password_length] || 6
    email_required? = Application.get_env(:elixircd, :services)[:nickserv][:email_required] || false
    max_nicks = Application.get_env(:elixircd, :services)[:nickserv][:max_nicks_per_user] || 3

    case RegisteredNicks.get_by_nickname(user.nick) do
      {:ok, _} ->
        send_notice(user, "This nick is already registered. Please choose a different nick.")

      {:error, _} ->
        validate_registration(user, password, email, min_password_length, email_required?, max_nicks)
    end

    :ok
  end

  def handle(user, ["REGISTER" | _rest_params]) do
    email_required? = Application.get_env(:elixircd, :services)[:nickserv][:email_required] || false

    send_notice(user, "Insufficient parameters for REGISTER.")
    send_notice(user, "Syntax: REGISTER <password> #{email_required_format(email_required?)}")
  end

  @spec validate_registration(User.t(), String.t(), String.t() | nil, integer(), boolean(), integer()) :: :ok
  defp validate_registration(user, password, email, min_password_length, email_required?, max_nicks) do
    with :ok <- validate_password(password, min_password_length),
         :ok <- validate_email(email, email_required?),
         :ok <- validate_nick_limit(user) do
      register_nickname(user, password, email)
    else
      {:error, :short_password} ->
        send_notice(user, "Password is too short. Please use at least #{min_password_length} characters.")
        send_notice(user, "Syntax: REGISTER <password> #{email_required_format(email_required?)}")

      {:error, :missing_email} ->
        send_notice(user, "You must provide an email address to register a nickname.")
        send_notice(user, "Syntax: REGISTER <password> #{email_required_format(email_required?)}")

      {:error, :invalid_email} ->
        send_notice(user, "Invalid email address. Please provide a valid email address.")
        send_notice(user, "Syntax: REGISTER <password> #{email_required_format(email_required?)}")

      {:error, :max_nicks_reached} ->
        send_notice(user, "You have reached the maximum number of registered nicknames (#{max_nicks}).")
        send_notice(user, "To drop a nickname, use /msg NickServ DROP <nickname>")
    end
  end

  @spec validate_password(String.t(), integer()) :: :ok | {:error, :short_password}
  defp validate_password(password, min_password_length) do
    if String.length(password) < min_password_length do
      {:error, :short_password}
    else
      :ok
    end
  end

  @spec validate_email(String.t() | nil, boolean()) :: :ok | {:error, :missing_email} | {:error, :invalid_email}
  defp validate_email(email, email_required?) do
    cond do
      email_required? && is_nil(email) -> {:error, :missing_email}
      !is_nil(email) && !valid_email?(email) -> {:error, :invalid_email}
      true -> :ok
    end
  end

  @spec validate_nick_limit(User.t()) :: :ok | {:error, :max_nicks_reached}
  defp validate_nick_limit(user) do
    if can_register_more_nicks?(user_mask(user)) do
      :ok
    else
      {:error, :max_nicks_reached}
    end
  end

  @spec register_nickname(User.t(), String.t(), String.t() | nil) :: :ok
  defp register_nickname(user, password, email) do
    password_hash = Pbkdf2.hash_pwd_salt(password)

    verify_code = if !is_nil(email), do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower), else: nil

    RegisteredNicks.create(%{
      nickname: user.nick,
      password_hash: password_hash,
      email: email,
      registered_by: user_mask(user),
      verify_code: verify_code
    })

    if !is_nil(email) do
      # Send verification email
      send_verification_email(email, user.nick, verify_code)

      send_notice(user, "An email containing nickname activation instructions has been sent to #{email}.")
      send_notice(user, "Please check the address if you don't receive it.")
      send_notice(user, "If it is incorrect, DROP then REGISTER again.")
      send_notice(user, "If you do not complete registration within one day, your nickname will expire.")
      send_notice(user, "#{user.nick} is now registered to #{email}.")
      # Future: Identify user if auto_identify is true
    else
      send_notice(user, "Your nickname has been successfully registered.")
      send_notice(user, "You are now identified for #{user.nick}.")
      # Future: Identify user if auto_identify is true
    end

    send_notice(user, "To identify in the future, type: /msg NickServ IDENTIFY #{user.nick} your_password")

    Logger.info("Nickname registered: #{user.nick} by #{user_mask(user)}")
  end

  @spec valid_email?(String.t()) :: boolean()
  defp valid_email?(email) do
    email_regex = ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/
    Regex.match?(email_regex, email)
  end

  @spec can_register_more_nicks?(String.t()) :: boolean()
  defp can_register_more_nicks?(host_ident) do
    max_nicks = Application.get_env(:elixircd, :services)[:nickserv][:max_nicks_per_user] || 3
    count_registered_nicks(host_ident) < max_nicks
  end

  @spec count_registered_nicks(String.t()) :: integer()
  defp count_registered_nicks(host_ident) do
    RegisteredNicks.get_all()
    |> Enum.count(fn reg_nick -> reg_nick.registered_by == host_ident end)
  end
end
