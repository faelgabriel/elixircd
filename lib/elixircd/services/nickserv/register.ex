defmodule ElixIRCd.Services.Nickserv.Register do
  @moduledoc """
  Module for the NickServ register command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Mailer, only: [send_verification_email: 3]
  import ElixIRCd.Utils.Nickserv, only: [notify: 2, email_required_format: 1]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["REGISTER", password | rest_params]) do
    email = Enum.at(rest_params, 0)

    min_password_length = Application.get_env(:elixircd, :services)[:nickserv][:min_password_length] || 6
    email_required? = Application.get_env(:elixircd, :services)[:nickserv][:email_required] || false
    wait_register_time = Application.get_env(:elixircd, :services)[:nickserv][:wait_register_time] || 0

    case RegisteredNicks.get_by_nickname(user.nick) do
      {:ok, _registered_nick} ->
        notify(user, "This nick is already registered. Please choose a different nick.")

      {:error, :registered_nick_not_found} ->
        validate_registration(user, password, email, min_password_length, email_required?, wait_register_time)
    end
  end

  def handle(user, ["REGISTER" | _command_params]) do
    email_required? = Application.get_env(:elixircd, :services)[:nickserv][:email_required] || false

    notify(user, [
      "Insufficient parameters for \x02REGISTER\x02.",
      "Syntax: \x02REGISTER <password> #{email_required_format(email_required?)}\x02"
    ])
  end

  @spec validate_registration(User.t(), String.t(), String.t() | nil, integer(), boolean(), integer()) :: :ok
  defp validate_registration(user, password, email, min_password_length, email_required?, wait_register_time) do
    with :ok <- validate_password(password, min_password_length),
         :ok <- validate_email(email, email_required?),
         :ok <- validate_connection_time(user, wait_register_time) do
      register_nickname(user, password, email)
    else
      {:error, :short_password} ->
        notify(user, "Password is too short. Please use at least #{min_password_length} characters.")
        notify(user, "Syntax: \x02REGISTER <password> #{email_required_format(email_required?)}\x02")

      {:error, :missing_email} ->
        notify(user, "You must provide an email address to register a nickname.")
        notify(user, "Syntax: \x02REGISTER <password> #{email_required_format(email_required?)}\x02")

      {:error, :invalid_email} ->
        notify(user, "Invalid email address. Please provide a valid email address.")
        notify(user, "Syntax: \x02REGISTER <password> #{email_required_format(email_required?)}\x02")

      {:error, :wait_register_time} ->
        time_left = calculate_time_left(user, wait_register_time)

        notify(user, "You must be connected for at least #{wait_register_time} seconds before you can register.")
        notify(user, "Please wait #{time_left} more seconds and try again.")
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

  @spec validate_connection_time(User.t(), integer()) :: :ok | {:error, :wait_register_time}
  defp validate_connection_time(user, wait_register_time) do
    if wait_register_time <= 0 do
      :ok
    else
      connected_for = DateTime.diff(DateTime.utc_now(), user.created_at)

      if connected_for >= wait_register_time do
        :ok
      else
        {:error, :wait_register_time}
      end
    end
  end

  @spec calculate_time_left(User.t(), integer()) :: integer()
  defp calculate_time_left(user, wait_register_time) do
    connected_for = DateTime.diff(DateTime.utc_now(), user.created_at)
    max(wait_register_time - connected_for, 0)
  end

  @spec register_nickname(User.t(), String.t(), String.t() | nil) :: :ok
  defp register_nickname(user, password, email) do
    password_hash = Argon2.hash_pwd_salt(password)
    verify_code = if is_nil(email), do: nil, else: :rand.bytes(4) |> Base.encode16(case: :lower)

    registered_nick =
      RegisteredNicks.create(%{
        nickname: user.nick,
        password_hash: password_hash,
        email: email,
        registered_by: user_mask(user),
        verify_code: verify_code
      })

    if is_nil(registered_nick.email) do
      notify(user, "Your nickname has been successfully registered.")
    else
      # Pending: Send email in a background job or task queue
      send_verification_email(registered_nick.email, user.nick, verify_code)

      unverified_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:unverified_expire_days] || 1

      notify(
        user,
        "An email containing nickname activation instructions has been sent to \x02#{registered_nick.email}\x02."
      )

      notify(
        user,
        "Please check the address if you don't receive it. If it is incorrect, \x02DROP\x02 then \x02REGISTER\x02 again."
      )

      if unverified_expire_days > 0 do
        notify(
          user,
          "If you do not complete registration within #{unverified_expire_days} #{pluralize_days(unverified_expire_days)}, your nickname will expire."
        )
      end

      notify(user, "\x02#{user.nick}\x02 is now registered to \x02#{registered_nick.email}\x02.")
    end

    notify(user, "To identify in the future, type: \x02/msg NickServ IDENTIFY #{user.nick} your_password\x02")
  end

  @spec pluralize_days(integer()) :: String.t()
  defp pluralize_days(1), do: "day"
  defp pluralize_days(_), do: "days"

  @spec valid_email?(String.t()) :: boolean()
  defp valid_email?(email) do
    email_regex = ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/
    Regex.match?(email_regex, email)
  end
end
