defmodule ElixIRCd.Jobs.VerificationEmailDelivery do
  @moduledoc """
  Job for delivering verification emails asynchronously through the job queue system.
  This job is enqueued on-demand when nickname registration requires email verification.
  """

  @behaviour ElixIRCd.Jobs.JobBehavior

  require Logger

  import ElixIRCd.Utils.Mailer, only: [send_verification_email: 3]

  alias ElixIRCd.Tables.Job

  @impl true
  @spec run(Job.t()) :: :ok | {:error, term()}
  def run(%Job{payload: %{"email" => email, "nickname" => nickname, "verification_code" => verification_code}}) do
    Logger.info("Sending verification email to #{email} for nickname #{nickname}")

    case send_verification_email(email, nickname, verification_code) do
      {:ok, _email} ->
        Logger.info("Successfully sent verification email to #{email} for nickname #{nickname}")
        :ok

      {:error, reason} ->
        error_message = "Failed to send verification email: #{inspect(reason)}"
        Logger.error(error_message)
        {:error, error_message}
    end
  end
end
