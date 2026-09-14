defmodule ElixIRCd.Utils.MailerTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  alias Bamboo.Mailer, as: BambooMailer
  alias ElixIRCd.Utils.Mailer

  describe "send_verification_email/3" do
    test "sends verification email with correct content" do
      BambooMailer
      |> expect(:deliver_now, fn _adapter, email, _config, _opts ->
        # Verify email content
        assert email.to == "test@example.com"
        assert email.from == "noreply@irc.test"
        assert email.subject == "test_nick IRC Nickname Registration Verification"

        # Verify HTML content contains the verification code
        assert email.html_body =~ "test_nick"
        assert email.html_body =~ "ABC123"
        assert email.html_body =~ "/msg NickServ VERIFY test_nick ABC123"

        # Verify text content contains the verification code
        assert email.text_body =~ "test_nick"
        assert email.text_body =~ "ABC123"
        assert email.text_body =~ "/msg NickServ VERIFY test_nick ABC123"

        {:ok, email}
      end)

      result = Mailer.send_verification_email("test@example.com", "test_nick", "ABC123")
      assert {:ok, _email} = result
    end

    test "uses configured sender email when available" do
      mailer_config = Application.fetch_env!(:elixircd, Mailer)

      Application
      |> expect(:fetch_env!, fn :elixircd, :services -> %{email: %{from_address: "custom@example.com"}} end)
      |> expect(:fetch_env!, fn :elixircd, Mailer -> mailer_config end)

      BambooMailer
      |> expect(:deliver_now, fn _adapter, email, _config, _opts ->
        # Verify the custom from address is used
        assert email.from == "custom@example.com"

        {:ok, email}
      end)

      result = Mailer.send_verification_email("test@example.com", "test_nick", "ABC123")
      assert {:ok, _email} = result
    end

    test "requires the configured sender instead of inventing an address" do
      expect(Application, :fetch_env!, fn :elixircd, :services ->
        raise ArgumentError, "missing services configuration"
      end)

      reject(BambooMailer, :deliver_now, 4)
      assert_raise ArgumentError, fn -> Mailer.send_verification_email("test@example.com", "test_nick", "ABC123") end
    end
  end
end
