defmodule ElixIRCd.Tables.SaslSessionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.SaslSession

  describe "new/1" do
    test "creates a new SASL session with required fields" do
      pid = self()

      session =
        SaslSession.new(%{
          user_pid: pid,
          mechanism: "PLAIN"
        })

      assert %SaslSession{} = session
      assert session.user_pid == pid
      assert session.mechanism == "PLAIN"
      assert session.buffer == ""
      assert session.state == nil
      assert %DateTime{} = session.created_at
    end

    test "creates a session with all fields specified" do
      pid = self()
      created_at = DateTime.utc_now()

      session =
        SaslSession.new(%{
          user_pid: pid,
          mechanism: "PLAIN",
          buffer: "test",
          state: %{test: true},
          created_at: created_at
        })

      assert session.user_pid == pid
      assert session.mechanism == "PLAIN"
      assert session.buffer == "test"
      assert session.state == %{test: true}
      assert session.created_at == created_at
    end
  end

  describe "update/2" do
    test "updates a SASL session" do
      pid = self()

      session =
        SaslSession.new(%{
          user_pid: pid,
          mechanism: "PLAIN",
          buffer: "initial"
        })

      updated_session =
        SaslSession.update(session, %{
          buffer: "updated"
        })

      assert updated_session.buffer == "updated"
      assert updated_session.mechanism == "PLAIN"
      assert updated_session.user_pid == pid
    end

    test "updates multiple fields" do
      pid = self()

      session =
        SaslSession.new(%{
          user_pid: pid,
          mechanism: "PLAIN"
        })

      updated_session =
        SaslSession.update(session, %{
          buffer: "test",
          state: %{authenticated: false}
        })

      assert updated_session.buffer == "test"
      assert updated_session.state == %{authenticated: false}
    end
  end
end
