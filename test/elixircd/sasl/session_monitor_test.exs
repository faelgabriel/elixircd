defmodule ElixIRCd.Sasl.SessionMonitorTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Sasl.SessionMonitor
  alias ElixIRCd.Tables.SaslSession

  describe "session timeout cleanup" do
    test "removes expired SASL sessions" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      # Set very short timeout for testing
      Application.put_env(:elixircd, :sasl, session_timeout_ms: 100)

      Memento.transaction!(fn ->
        user = insert(:user)

        # Create an old session
        old_time = DateTime.add(DateTime.utc_now(), -200, :millisecond)

        session = %SaslSession{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: "",
          created_at: old_time
        }

        Memento.Query.write(session)
      end)

      # Manually trigger cleanup
      send(SessionMonitor, :check_timeouts)
      :timer.sleep(100)

      # Verify session was removed
      result =
        Memento.transaction!(fn ->
          SaslSession
          |> Memento.Query.all()
          |> Enum.empty?()
        end)

      assert result == true
    end

    test "keeps non-expired SASL sessions" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl, session_timeout_ms: 60_000)

      Memento.transaction!(fn ->
        user = insert(:user)

        # Create a recent session
        session = %SaslSession{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: "",
          created_at: DateTime.utc_now()
        }

        Memento.Query.write(session)
      end)

      # Manually trigger cleanup
      send(SessionMonitor, :check_timeouts)
      :timer.sleep(100)

      # Verify session still exists
      result =
        Memento.transaction!(fn ->
          SaslSession
          |> Memento.Query.all()
          |> length()
        end)

      assert result == 1
    end
  end

  describe "cleanup when user no longer exists" do
    setup do
      Mimic.copy(ElixIRCd.Repositories.Users)
      :ok
    end

    @tag :capture_log
    test "removes session without broadcasting when user missing" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl, session_timeout_ms: 100)

      Memento.transaction!(fn ->
        # Session with a PID that has no associated user
        old_time = DateTime.add(DateTime.utc_now(), -200, :millisecond)

        session = %SaslSession{
          user_pid: self(),
          mechanism: "PLAIN",
          buffer: "",
          created_at: old_time
        }

        Memento.Query.write(session)
      end)

      stub(ElixIRCd.Repositories.Users, :get_by_pid, fn _pid -> {:error, :not_found} end)

      send(SessionMonitor, :check_timeouts)
      :timer.sleep(100)

      result =
        Memento.transaction!(fn ->
          SaslSession
          |> Memento.Query.all()
          |> Enum.empty?()
        end)

      assert result == true
    end
  end
end
