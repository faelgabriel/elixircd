defmodule ElixIRCd.Server.ListenersTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Server.Listeners

  describe "init/1" do
    for scheme <- [:http, :https] do
      test "sets the fragmented message limit in the #{scheme} child spec" do
        server_opts = [port: 8080, websocket_options: [compress: false, max_fragmented_message_size: 0]]

        assert {:ok, {_flags, [child]}} = Listeners.init([{unquote(scheme), server_opts}])
        assert {Bandit, :start_link, [opts]} = child.start
        assert opts[:scheme] == unquote(scheme)
        assert opts[:websocket_options] == [max_fragmented_message_size: 4608, compress: false]
      end
    end

    test "sets the fragmented message limit in the child spec without existing WebSocket options" do
      assert {:ok, {_flags, [child]}} = Listeners.init(http: [port: 8080])
      assert {Bandit, :start_link, [opts]} = child.start
      assert opts[:websocket_options] == [max_fragmented_message_size: 4608]
    end
  end
end
