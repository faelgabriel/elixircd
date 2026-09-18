defmodule ElixIRCd.Jobs.MemoEmailDeliveryTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  alias ElixIRCd.Jobs.MemoEmailDelivery
  alias ElixIRCd.Tables.Job

  describe "memo email delivery job" do
    test "handles successful email sending" do
      job = %Job{
        module: MemoEmailDelivery,
        payload: %{
          "email" => "recipient@example.com",
          "recipient" => "Account",
          "sender" => "Sender",
          "body" => "Hello"
        }
      }

      expect(ElixIRCd.Utils.Mailer, :send_memo_email, fn
        "recipient@example.com", "Account", "Sender", "Hello" -> {:ok, :sent}
      end)

      assert MemoEmailDelivery.run(job) == :ok
    end

    test "returns a retryable error when email sending fails" do
      job = %Job{
        module: MemoEmailDelivery,
        payload: %{
          "email" => "recipient@example.com",
          "recipient" => "Account",
          "sender" => "Sender",
          "body" => "Hello"
        }
      }

      expect(ElixIRCd.Utils.Mailer, :send_memo_email, fn
        "recipient@example.com", "Account", "Sender", "Hello" -> {:error, :smtp_unavailable}
      end)

      assert MemoEmailDelivery.run(job) ==
               {:error, "Failed to send memo email: :smtp_unavailable"}
    end
  end
end
