defmodule ElixIRCd.Utils.Mailer do
  @moduledoc """
  Email utility module for sending emails using Bamboo.
  Centralizes email sending functionality for the application.
  """

  use Bamboo.Mailer, otp_app: :elixircd

  import Bamboo.Email

  @doc """
  Sends a verification email for nickname registration.

  ## Parameters
    * `to` - Email address of the recipient
    * `nickname` - The IRC nickname being registered
    * `verification_code` - The verification code to include in the email
  """
  @spec send_verification_email(String.t(), String.t(), String.t()) :: {:ok, Bamboo.Email.t()} | {:error, any()}
  def send_verification_email(to, nickname, verification_code) do
    new_email()
    |> to(to)
    |> from(sender_email())
    |> subject("#{nickname} IRC Nickname Registration Verification")
    |> html_body(verification_email_html(nickname, verification_code))
    |> text_body(verification_email_text(nickname, verification_code))
    |> deliver_now()
  end

  @spec sender_email() :: String.t()
  defp sender_email do
    host = Application.get_env(:elixircd, :server)[:hostname]
    Application.get_env(:elixircd, :services)[:email][:from_address] || "noreply@#{host}"
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
end
