defmodule ElixIRCd.Jobs.SaslSessionExpirationTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Jobs.SaslSessionExpiration
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Tables.Job

  setup do
    original_sasl = Application.get_env(:elixircd, :sasl)

    on_exit(fn ->
      Application.put_env(:elixircd, :sasl, original_sasl)
    end)

    Application.put_env(
      :elixircd,
      :sasl,
      session_timeout_ms: 60_000
    )

    :ok
  end

  describe "schedule/0" do
    test "schedules the job with correct parameters" do
      Memento.transaction!(fn ->
        job = SaslSessionExpiration.schedule()

        assert job.module == SaslSessionExpiration
        assert job.status == :queued
        assert job.max_attempts == 3
        assert job.retry_delay_ms == 5_000
        assert job.repeat_interval_ms == 30_000
      end)
    end
  end

  describe "run/1" do
    test "cleans up expired SASL sessions" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        # Create an expired session (created 2 minutes ago)
        _expired_session =
          SaslSessions.create(%{
            user_pid: user.pid,
            mechanism: "PLAIN",
            buffer: "",
            created_at: DateTime.add(DateTime.utc_now(), -120, :second)
          })

        job = %Job{
          id: "test-job",
          module: SaslSessionExpiration,
          payload: %{},
          status: :processing,
          scheduled_at: DateTime.utc_now(),
          current_attempt: 1,
          max_attempts: 3,
          retry_delay_ms: 5_000,
          repeat_interval_ms: 30_000,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        assert :ok = SaslSessionExpiration.run(job)

        # Verify the session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)

        # Verify the user received an error message
        assert_sent_messages([
          {user.pid, ":irc.test 906 #{user.nick} :SASL authentication timeout\r\n"}
        ])
      end)
    end

    test "does not clean up recent SASL sessions" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        # Create a recent session
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        job = %Job{
          id: "test-job",
          module: SaslSessionExpiration,
          payload: %{},
          status: :processing,
          scheduled_at: DateTime.utc_now(),
          current_attempt: 1,
          max_attempts: 3,
          retry_delay_ms: 5_000,
          repeat_interval_ms: 30_000,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        assert :ok = SaslSessionExpiration.run(job)

        # Verify the session still exists
        assert {:ok, _session} = SaslSessions.get(user.pid)

        # Verify no messages were sent
        assert_sent_messages([])
      end)
    end

    test "handles session cleanup when user no longer exists" do
      Memento.transaction!(fn ->
        # Create a session with a non-existent user PID
        fake_pid = spawn(fn -> :ok end)
        Process.exit(fake_pid, :kill)

        # Wait for process to die
        Process.sleep(10)

        SaslSessions.create(%{
          user_pid: fake_pid,
          mechanism: "PLAIN",
          buffer: "",
          created_at: DateTime.add(DateTime.utc_now(), -120, :second)
        })

        job = %Job{
          id: "test-job",
          module: SaslSessionExpiration,
          payload: %{},
          status: :processing,
          scheduled_at: DateTime.utc_now(),
          current_attempt: 1,
          max_attempts: 3,
          retry_delay_ms: 5_000,
          repeat_interval_ms: 30_000,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        # Should not crash
        assert :ok = SaslSessionExpiration.run(job)

        # Verify the session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(fake_pid)
      end)
    end

    test "returns :ok when no sessions exist" do
      Memento.transaction!(fn ->
        job = %Job{
          id: "test-job",
          module: SaslSessionExpiration,
          payload: %{},
          status: :processing,
          scheduled_at: DateTime.utc_now(),
          current_attempt: 1,
          max_attempts: 3,
          retry_delay_ms: 5_000,
          repeat_interval_ms: 30_000,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        assert :ok = SaslSessionExpiration.run(job)
      end)
    end
  end
end
