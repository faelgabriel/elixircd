defmodule ElixIRCd.Server.S2S.ListenerTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Listener

  test "transport callbacks before session initialization are safe" do
    assert :ok = Listener.handle_error(:tls_alert, nil, [])
    assert :ok = Listener.handle_timeout(nil, [])
    assert :ok = Listener.handle_shutdown(nil, [])
    assert :ok = Listener.handle_close(nil, [])
  end
end
