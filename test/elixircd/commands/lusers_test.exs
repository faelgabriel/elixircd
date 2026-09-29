defmodule ElixIRCd.Commands.LusersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Lusers
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Metrics
  alias ElixIRCd.ServerLink.NetworkStats
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.UserPayload

  describe "handle/2" do
    test "reports committed global counts across direct and transitive links" do
      original = Application.fetch_env!(:elixircd, :server_links)
      on_exit(fn -> Application.put_env(:elixircd, :server_links, original) end)
      Application.put_env(:elixircd, :server_links, Keyword.put(original, :enabled, true))

      table = NetworkStats.create()
      uid = UserPayload.new_uid()
      remote = build(:user, nick: "Remote", modes: [:i, :o]) |> UserPayload.from_local(uid)
      replica = %{Replica.new() | users: %{{"west.example", uid} => remote}}
      route = %Route{via: "east.example", epoch: uid, path: ["west.example", "east.example", "irc.test"]}

      NetworkStats.publish(
        table,
        replica,
        %{"east.example" => route, "west.example" => route},
        %{"east.example" => self()},
        %{"#linked" => :selected}
      )

      Memento.transaction!(fn ->
        Metrics |> expect(:get, 1, fn :highest_users -> 10 end)
        viewer = insert(:user, nick: "Viewer")
        insert(:user, nick: "LocalHidden", modes: [:i])
        assert :ok = Lusers.handle(viewer, %Message{command: "LUSERS", params: []})

        assert_sent_messages([
          {viewer.pid, ":irc.test 251 Viewer :There are 1 users and 2 invisible on 3 servers\r\n"},
          {viewer.pid, ":irc.test 252 Viewer 1 :operator(s) online\r\n"},
          {viewer.pid, ":irc.test 253 Viewer 0 :unknown connection(s)\r\n"},
          {viewer.pid, ":irc.test 254 Viewer 1 :channels formed\r\n"},
          {viewer.pid, ":irc.test 255 Viewer :I have 2 clients and 1 servers\r\n"},
          {viewer.pid, ":irc.test 265 Viewer 2 10 :Current local users 2, max 10\r\n"},
          {viewer.pid, ":irc.test 266 Viewer 3 10 :Current global users 3, max 10\r\n"}
        ])
      end)
    end

    test "does not invent standalone totals when the enabled network view is unavailable" do
      original = Application.fetch_env!(:elixircd, :server_links)
      on_exit(fn -> Application.put_env(:elixircd, :server_links, original) end)
      Application.put_env(:elixircd, :server_links, Keyword.put(original, :enabled, true))

      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        assert :ok = Lusers.handle(viewer, %Message{command: "LUSERS", params: []})

        assert_sent_messages([
          {viewer.pid, ":irc.test 437 Viewer LUSERS :Network statistics are temporarily unavailable\r\n"}
        ])
      end)
    end

    test "handles LUSERS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "LUSERS", params: ["#anything"]}

        assert :ok = Lusers.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles LUSERS command" do
      Memento.transaction!(fn ->
        Metrics
        |> expect(:get, 1, fn :highest_users -> 10 end)

        insert(:user, registered: true, modes: [])
        insert(:user, registered: true, modes: [:i])
        insert(:user, registered: true, modes: [:o])
        insert(:user, registered: false)

        user = insert(:user)
        message = %Message{command: "LUSERS", params: []}

        assert :ok = Lusers.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 251 #{user.nick} :There are 3 users and 1 invisible on 1 server\r\n"},
          {user.pid, ":irc.test 252 #{user.nick} 1 :operator(s) online\r\n"},
          {user.pid, ":irc.test 253 #{user.nick} 1 :unknown connection(s)\r\n"},
          {user.pid, ":irc.test 254 #{user.nick} 0 :channels formed\r\n"},
          {user.pid, ":irc.test 255 #{user.nick} :I have 4 clients and 0 servers\r\n"},
          {user.pid, ":irc.test 265 #{user.nick} 4 10 :Current local users 4, max 10\r\n"},
          {user.pid, ":irc.test 266 #{user.nick} 4 10 :Current global users 4, max 10\r\n"}
        ])
      end)
    end
  end
end
