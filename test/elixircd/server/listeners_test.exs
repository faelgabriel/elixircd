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

    test "routes HTTPS CA and TLS versions to Bandit's transport options" do
      server_opts = [
        port: 8443,
        startup_log: false,
        websocket_options: [compress: false],
        keyfile: "/key.pem",
        certfile: "/cert.pem",
        cacertfile: "/ca.pem",
        versions: [:"tlsv1.3"],
        thousand_island_options: [num_acceptors: 10]
      ]

      assert {:ok, {_flags, [child]}} = Listeners.init(https: server_opts)
      assert {Bandit, :start_link, [opts]} = child.start
      refute Keyword.has_key?(opts, :cacertfile)
      refute Keyword.has_key?(opts, :versions)
      assert opts[:thousand_island_options][:num_acceptors] == 10
      assert opts[:thousand_island_options][:transport_options] == [cacertfile: "/ca.pem", versions: [:"tlsv1.3"]]
    end

    test "requires explicit WebSocket options" do
      assert_raise KeyError, fn -> Listeners.init(http: [port: 8080]) end
    end
  end
end
