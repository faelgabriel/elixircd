defmodule ElixIRCd.Jobs.MemoEmailDelivery do
  @moduledoc "Job for delivering a NickServ memo to an account email address."

  @behaviour ElixIRCd.Jobs.JobBehavior

  require Logger

  import ElixIRCd.Utils.Mailer, only: [send_memo_email: 4]

  alias ElixIRCd.Tables.Job

  @impl true
  @spec run(Job.t()) :: :ok | {:error, term()}
  def run(%Job{
        payload: %{
          "email" => email,
          "recipient" => recipient,
          "sender" => sender,
          "body" => body
        }
      }) do
    Logger.info("Sending NickServ memo email", event: "email.memo_started")

    case send_memo_email(email, recipient, sender, body) do
      {:ok, _email} -> :ok
      {:error, reason} -> {:error, "Failed to send memo email: #{inspect(reason)}"}
    end
  end
end
