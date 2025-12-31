defmodule ElixIRCd.Repositories.SaslSessionsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Tables.SaslSession

  describe "create/1" do
    test "creates a new SASL session" do
      Memento.transaction!(fn ->
        user = insert(:user)

        session =
          SaslSessions.create(%{
            user_pid: user.pid,
            mechanism: "PLAIN",
            buffer: "test"
          })

        assert %SaslSession{} = session
        assert session.user_pid == user.pid
        assert session.mechanism == "PLAIN"
        assert session.buffer == "test"
        assert session.state == nil
        assert %DateTime{} = session.created_at
      end)
    end

    test "creates a session with defaults" do
      Memento.transaction!(fn ->
        user = insert(:user)

        session =
          SaslSessions.create(%{
            user_pid: user.pid,
            mechanism: "PLAIN"
          })

        assert session.buffer == ""
        assert session.state == nil
        assert %DateTime{} = session.created_at
      end)
    end
  end

  describe "get/1" do
    test "retrieves an existing SASL session" do
      Memento.transaction!(fn ->
        user = insert(:user)

        created_session =
          SaslSessions.create(%{
            user_pid: user.pid,
            mechanism: "PLAIN"
          })

        assert {:ok, session} = SaslSessions.get(user.pid)
        assert session.user_pid == created_session.user_pid
        assert session.mechanism == created_session.mechanism
      end)
    end

    test "returns error for non-existent session" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end
  end

  describe "get_all/0" do
    test "retrieves all SASL sessions" do
      Memento.transaction!(fn ->
        user1 = insert(:user)
        user2 = insert(:user)

        SaslSessions.create(%{
          user_pid: user1.pid,
          mechanism: "PLAIN"
        })

        SaslSessions.create(%{
          user_pid: user2.pid,
          mechanism: "PLAIN"
        })

        sessions = SaslSessions.get_all()
        assert length(sessions) == 2
      end)
    end

    test "returns empty list when no sessions exist" do
      Memento.transaction!(fn ->
        sessions = SaslSessions.get_all()
        assert sessions == []
      end)
    end
  end

  describe "update/2" do
    test "updates a SASL session" do
      Memento.transaction!(fn ->
        user = insert(:user)

        session =
          SaslSessions.create(%{
            user_pid: user.pid,
            mechanism: "PLAIN",
            buffer: "initial"
          })

        updated_session =
          SaslSessions.update(session, %{
            buffer: "updated"
          })

        assert updated_session.buffer == "updated"
        assert updated_session.mechanism == "PLAIN"

        # Verify it was persisted
        {:ok, persisted} = SaslSessions.get(user.pid)
        assert persisted.buffer == "updated"
      end)
    end
  end

  describe "delete/1" do
    test "deletes a SASL session" do
      Memento.transaction!(fn ->
        user = insert(:user)

        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN"
        })

        assert {:ok, _session} = SaslSessions.get(user.pid)

        assert :ok = SaslSessions.delete(user.pid)

        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "returns :ok even when session doesn't exist" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = SaslSessions.delete(user.pid)
      end)
    end
  end

  describe "exists?/1" do
    test "returns true when session exists" do
      Memento.transaction!(fn ->
        user = insert(:user)

        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN"
        })

        assert SaslSessions.exists?(user.pid) == true
      end)
    end

    test "returns false when session doesn't exist" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert SaslSessions.exists?(user.pid) == false
      end)
    end
  end
end
