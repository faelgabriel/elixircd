defmodule ElixIRCd.Utils.Mailer do
  @moduledoc """
  Email utility module for sending emails using Bamboo.
  Centralizes email sending functionality for the application.
  """

  use Bamboo.Mailer, otp_app: :elixircd

  import Bamboo.Email

  alias ElixIRCd.Observability

  @doc """
  Sends a verification email for nickname registration.

  ## Parameters
    * `to` - Email address of the recipient
    * `nickname` - The IRC nickname being registered
    * `verification_code` - The verification code to include in the email
  """
  @spec send_verification_email(String.t(), String.t(), String.t()) :: {:ok, Bamboo.Email.t()} | {:error, any()}
  def send_verification_email(to, nickname, verification_code) do
    started = System.monotonic_time()

    result =
      new_email()
      |> to(to)
      |> from(sender_email())
      |> subject("#{nickname} IRC Nickname Registration Verification")
      |> html_body(verification_email_html(nickname, verification_code))
      |> text_body(verification_email_text(nickname, verification_code))
      |> deliver_now()

    observe_delivery(:verification, result, started)
    result
  end

  @doc "Sends a one-time NickServ password reset code."
  @spec send_password_reset_email(String.t(), String.t(), String.t()) :: {:ok, Bamboo.Email.t()} | {:error, any()}
  def send_password_reset_email(to, account_name, code) do
    started = System.monotonic_time()
    command = "/msg NickServ RESETPASS CONFIRM #{account_name} #{code} <new-password>"

    result =
      new_email()
      |> to(to)
      |> from(sender_email())
      |> subject("IRC account password reset")
      |> html_body(
        "<p>A password reset was requested for #{escape_html(account_name)}.</p>" <>
          "<p>Connect securely to IRC and use this command within 30 minutes:</p><pre>#{escape_html(command)}</pre>" <>
          "<p>If you did not request this, ignore this email.</p>"
      )
      |> text_body(
        "A password reset was requested for #{account_name}.\n" <>
          "Connect securely to IRC and use this command within 30 minutes:\n#{command}\n" <>
          "If you did not request this, ignore this email.\n"
      )
      |> deliver_now()

    observe_delivery(:password_reset, result, started)
    result
  end

  @doc "Sends a stored NickServ memo to the recipient's configured email address."
  @spec send_memo_email(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Bamboo.Email.t()} | {:error, any()}
  def send_memo_email(to, recipient, sender, body) do
    started = System.monotonic_time()

    result =
      new_email()
      |> to(to)
      |> from(sender_email())
      |> subject("IRC memo for #{recipient}")
      |> html_body(memo_email_html(recipient, sender, body))
      |> text_body(memo_email_text(recipient, sender, body))
      |> deliver_now()

    observe_delivery(:memo, result, started)
    result
  end

  defp observe_delivery(purpose, result, started) do
    status = if match?({:ok, _}, result), do: :success, else: :failure

    Observability.emit([:email], %{count: 1, duration: System.monotonic_time() - started}, %{
      purpose: purpose,
      result: status
    })
  end

  @spec sender_email() :: String.t()
  defp sender_email do
    Application.fetch_env!(:elixircd, :services)[:email][:from_address]
  end

  @spec verification_email_html(String.t(), String.t()) :: String.t()
  defp verification_email_html(nickname, verification_code) do
    """
    <html>
      <body>
        <h1>IRC Nickname Registration Verification</h1>
        <p>Hello,</p>
        <p>You (or someone) has registered the nickname <strong>#{nickname}</strong> on our IRC network.</p>
        <p>To complete your registration, please use the following command on IRC:</p>
        <pre>/msg NickServ VERIFY #{nickname} #{verification_code}</pre>
        <p>If you did not register this nickname, you can safely ignore this email.</p>
        <p>Thank you,<br>IRC Network Team</p>
      </body>
    </html>
    """
  end

  @spec verification_email_text(String.t(), String.t()) :: String.t()
  defp verification_email_text(nickname, verification_code) do
    """
    IRC Nickname Registration Verification

    Hello,

    You (or someone) has registered the nickname #{nickname} on our IRC network.

    To complete your registration, please use the following command on IRC:

    /msg NickServ VERIFY #{nickname} #{verification_code}

    If you did not register this nickname, you can safely ignore this email.

    Thank you,
    IRC Network Team
    """
  end

  @spec memo_email_html(String.t(), String.t(), String.t()) :: String.t()
  defp memo_email_html(recipient, sender, body) do
    """
    <html>
      <body>
        <h1>NickServ memo</h1>
        <p>A memo for <strong>#{escape_html(recipient)}</strong> was sent by <strong>#{escape_html(sender)}</strong>.</p>
        <p>#{escape_html(body) |> String.replace("\n", "<br>")}</p>
      </body>
    </html>
    """
  end

  @spec memo_email_text(String.t(), String.t(), String.t()) :: String.t()
  defp memo_email_text(recipient, sender, body) do
    """
    NickServ memo

    A memo for #{recipient} was sent by #{sender}.

    #{body}
    """
  end

  @spec escape_html(String.t()) :: String.t()
  defp escape_html(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
