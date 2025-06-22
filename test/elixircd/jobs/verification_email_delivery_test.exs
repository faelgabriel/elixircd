defmodule ElixIRCd.Jobs.VerificationEmailDeliveryTest do
  use ElixIRCd.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias ElixIRCd.Jobs.VerificationEmailDelivery
  alias ElixIRCd.Tables.Job

  describe "verification email delivery job" do
    @tag :capture_log
    test "handles successful email sending" do
      job = %Job{
        module: VerificationEmailDelivery,
        payload: %{
          "email" => "test@example.com",
          "nickname" => "testuser",
          "verification_code" => "abc123"
        }
      }

      expect(ElixIRCd.Utils.Mailer, :send_verification_email, fn
        "test@example.com", "testuser", "abc123" -> {:ok, %Bamboo.Email{}}
      end)

      result = VerificationEmailDelivery.run(job)
      assert result == :ok
    end

    test "handles send_verification_email failure" do
      job = %Job{
        module: VerificationEmailDelivery,
        payload: %{
          "email" => "test@example.com",
          "nickname" => "testuser",
          "verification_code" => "abc123"
        }
      }

      expect(ElixIRCd.Utils.Mailer, :send_verification_email, fn
        "test@example.com", "testuser", "abc123" -> {:error, "SMTP error"}
      end)

      log_output =
        capture_log(fn ->
          result = VerificationEmailDelivery.run(job)
          assert {:error, error_message} = result
          assert error_message =~ "Failed to send verification email"
        end)

      assert log_output =~ "Failed to send verification email"
    end

    test "handles missing email in payload" do
      job = %Job{
        module: VerificationEmailDelivery,
        payload: %{
          "nickname" => "testuser",
          "verification_code" => "abc123"
        }
      }

      log_output =
        capture_log(fn ->
          result = VerificationEmailDelivery.run(job)
          assert {:error, error_message} = result
          assert error_message =~ "Invalid payload"
        end)

      assert log_output =~ "Invalid payload"
    end

    test "handles missing nickname in payload" do
      job = %Job{
        module: VerificationEmailDelivery,
        payload: %{
          "email" => "test@example.com",
          "verification_code" => "abc123"
        }
      }

      log_output =
        capture_log(fn ->
          result = VerificationEmailDelivery.run(job)
          assert {:error, error_message} = result
          assert error_message =~ "Invalid payload"
        end)

      assert log_output =~ "Invalid payload"
    end

    test "handles missing verification_code in payload" do
      job = %Job{
        module: VerificationEmailDelivery,
        payload: %{
          "email" => "test@example.com",
          "nickname" => "testuser"
        }
      }

      log_output =
        capture_log(fn ->
          result = VerificationEmailDelivery.run(job)
          assert {:error, error_message} = result
          assert error_message =~ "Invalid payload"
        end)

      assert log_output =~ "Invalid payload"
    end

    test "handles completely invalid payload" do
      job = %Job{
        module: VerificationEmailDelivery,
        payload: %{
          "invalid" => "data"
        }
      }

      log_output =
        capture_log(fn ->
          result = VerificationEmailDelivery.run(job)
          assert {:error, error_message} = result
          assert error_message =~ "Invalid payload"
        end)

      assert log_output =~ "Invalid payload"
    end
  end
end
