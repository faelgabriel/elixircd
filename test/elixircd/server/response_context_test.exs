defmodule ElixIRCd.Server.ResponseContextTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext

  setup do
    original_config = Application.get_env(:elixircd, :capabilities)
    on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

    Application.put_env(
      :elixircd,
      :capabilities,
      original_config |> Keyword.put(:batch, true) |> Keyword.put(:labeled_response, true)
    )

    :ok
  end

  for {disabled, retains_batch?} <- [batch: false, labeled_response: true] do
    test "finishes a labeled REHASH before announcing removal of #{disabled}" do
      disabled = unquote(disabled)
      user = insert(:user, pid: self(), modes: ["o"], capabilities: ["batch", "labeled-response", "cap-notify"])

      stub(ElixIRCd.Utils.System, :load_configurations, fn ->
        config = Application.get_env(:elixircd, :capabilities)
        Application.put_env(:elixircd, :capabilities, Keyword.put(config, disabled, false))
      end)

      dispatch(user, "@label=rehash REHASH")
      [start, rehashing, completed, finish, notification] = wire_messages()
      assert_batch([start, rehashing, completed, finish], "rehash")
      assert rehashing.command == "382"
      assert completed.trailing == "Rehashing completed"
      assert notification.command == "CAP"
      assert notification.params == [user.nick, "DEL"]
      assert notification.tags == %{}

      updated_user = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end) |> elem(1)
      refute "labeled-response" in updated_user.capabilities
      assert "batch" in updated_user.capabilities == unquote(retains_batch?)

      dispatch(updated_user, "@label=after-rehash PING :probe")
      assert [%Message{command: "PONG", tags: tags}] = wire_messages()
      assert tags == %{}
    end
  end

  test "retains negotiated framing for clients without CAP DEL support" do
    user = insert(:user, pid: self(), capabilities: ["batch", "labeled-response"])
    config = Application.get_env(:elixircd, :capabilities)
    Application.put_env(:elixircd, :capabilities, config |> Keyword.put(:batch, false))

    dispatch(user, "@label=still-negotiated PING :probe")
    assert [%Message{command: "PONG", tags: %{"label" => "still-negotiated"}}] = wire_messages()

    dispatch(user, "@label=disable CAP REQ :-batch")
    assert [%Message{command: "CAP", params: [_, "ACK"], tags: %{"label" => "disable"}}] = wire_messages()

    updated_user = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end) |> elem(1)
    refute "batch" in updated_user.capabilities
  end

  test "flushes the entire self KILL response before the disconnect signal" do
    user = insert(:user, pid: self(), modes: ["o", "s"], capabilities: ["batch", "labeled-response"])
    dispatch(user, "@label=kill KILL #{user.nick} :test")

    events = output_events()
    assert {:disconnect, reason} = List.last(events)

    assert [{:broadcast, start}, {:broadcast, error}, {:broadcast, notice}, {:broadcast, finish}] =
             Enum.drop(events, -1)

    messages = Enum.map([start, error, notice, finish], &Message.parse!/1)
    assert_batch(messages, "kill")
    assert Enum.at(messages, 1).command == "ERROR"
    assert Enum.at(messages, 2).command == "NOTICE"
    assert reason == "Killed (#{user.nick} (test))"
  end

  test "disconnecting another user keeps the requester's response open" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])
    target = build(:user)

    ResponseContext.with_command(user, Message.parse!("@label=caller PING :probe"), fn ->
      Dispatcher.disconnect(target, "test")
      Dispatcher.broadcast(%Message{command: "NOTICE", params: [user.nick], trailing: "done"}, :server, user)
    end)

    assert [%Message{command: "NOTICE", tags: %{"label" => "caller"}}] = wire_messages()
  end

  describe "server shutdown commands" do
    setup :set_mimic_global

    for command <- ["DIE", "RESTART"] do
      test "#{command} closes the operator's batch before disconnecting" do
        command = unquote(command)
        test_pid = self()
        user = insert(:user, pid: self(), modes: ["o"], capabilities: ["batch", "labeled-response"])

        if command == "DIE" do
          expect(System, :halt, fn 0 -> send(test_pid, :shutdown_requested) end)
        else
          expect(Application, :stop, fn :elixircd -> :ok end)
          expect(Application, :start, fn :elixircd -> send(test_pid, :shutdown_requested) end)
        end

        dispatch(user, "@label=shutdown #{command} :test")
        events = output_events()
        assert {:disconnect, _reason} = List.last(events)
        messages = for {:broadcast, wire} <- events, do: Message.parse!(wire)
        assert_batch(messages, "shutdown")
        assert Enum.map(messages, & &1.command) == ["BATCH", "NOTICE", "ERROR", "BATCH"]
        assert_receive :shutdown_requested, 1_000
      end
    end
  end

  for order <- [["batch", "labeled-response"], ["labeled-response", "batch"]] do
    test "accepts separate CAP REQs in order #{inspect(order)}" do
      user = insert(:user, pid: self(), capabilities: [])

      user =
        Enum.reduce(unquote(order), user, fn capability, user ->
          dispatch(user, "CAP REQ :#{capability}")
          assert [%Message{command: "CAP", params: [_, "ACK"]}] = wire_messages()
          Memento.transaction!(fn -> Users.get_by_pid(user.pid) end) |> elem(1)
        end)

      dispatch(user, "@label=ready PING :probe")
      assert [%Message{command: "PONG", tags: %{"label" => "ready"}}] = wire_messages()
    end
  end

  for missing <- ["batch", "labeled-response"] do
    test "ignores labels without negotiated #{missing}" do
      caps = ["batch", "labeled-response"] -- [unquote(missing)]
      user = insert(:user, pid: self(), capabilities: caps)
      dispatch(user, "@label=ignored PING :probe")
      assert [%Message{command: "PONG", tags: tags}] = wire_messages()
      assert tags == %{}
    end
  end

  for label_tag <- ["label", "label=", "label=\\", "label=" <> String.duplicate("x", 65)] do
    test "ignores invalid label tag #{inspect(label_tag)}" do
      user = insert(:user, pid: self(), capabilities: ["batch", "labeled-response"])
      dispatch(user, "@#{unquote(label_tag)} PING :probe")
      assert [%Message{command: "PONG", tags: tags}] = wire_messages()
      assert tags == %{}
    end
  end

  for command <- ["PRIVMSG", "NOTICE", "TAGMSG"], echo? <- [false, true] do
    test "real #{command} self delivery with echo-message #{echo?}" do
      caps = ["batch", "labeled-response", "message-tags"]
      caps = if unquote(echo?), do: ["echo-message" | caps], else: caps
      user = insert(:user, pid: self(), capabilities: caps)
      trailing = if unquote(command) == "TAGMSG", do: "", else: " :hello"

      dispatch(user, "@label=self;+example.test/tag=value #{unquote(command)} #{user.nick}#{trailing}")
      [delivered | echoed] = wire_messages()
      assert delivered.command == unquote(command)
      msgid = delivered.tags["msgid"]
      assert msgid =~ ~r/^[A-Za-z0-9_-]{24}$/
      assert delivered.tags == %{"+example.test/tag" => "value", "msgid" => msgid}

      if unquote(echo?) do
        assert [%Message{tags: tags}] = echoed
        assert tags == Map.put(delivered.tags, "label", "self")
      else
        assert echoed == []
      end
    end
  end

  test "nested batches carry the enclosing reference on both boundaries" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])

    ResponseContext.with_command(user, Message.parse!("@label=nested PING :probe"), fn ->
      ResponseContext.with_batch("example.test/outer", fn ->
        ResponseContext.with_batch("example.test/inner", fn ->
          Dispatcher.broadcast(%Message{command: "NOTICE", params: [user.nick], trailing: "nested"}, :server, user)
        end)
      end)
    end)

    [outer_start, inner_start, content, inner_end, outer_end] = wire_messages()
    ["+" <> outer_ref, _type] = outer_start.params
    ["+" <> inner_ref, _type] = inner_start.params
    assert outer_start.tags == %{"label" => "nested"}
    assert inner_start.tags == %{"batch" => outer_ref}
    assert content.tags == %{"batch" => inner_ref}
    assert inner_end.tags == %{"batch" => outer_ref}
    assert inner_end.params == ["-" <> inner_ref]
    assert outer_end.params == ["-" <> outer_ref]
    assert outer_end.tags == %{}
  end

  for tag <- ["", "@label= ", "@label=" <> String.duplicate("x", 65) <> " "] do
    test "preserves self-message deduplication without a valid label: #{inspect(tag)}" do
      user = insert(:user, pid: self(), capabilities: ["batch", "labeled-response", "echo-message"])
      dispatch(user, unquote(tag) <> "PRIVMSG #{user.nick} :hello")
      assert [%Message{command: "PRIVMSG", tags: %{}}] = wire_messages()
    end
  end

  test "concurrent connection processes keep labels and buffers isolated" do
    tasks =
      for label <- ["one", "two"] do
        Task.async(fn ->
          user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])

          ResponseContext.with_command(user, Message.parse!("@label=#{label} PING :probe"), fn ->
            Dispatcher.broadcast(%Message{command: "NOTICE", params: [user.nick], trailing: label}, :server, user)
          end)

          assert ResponseContext.current() == nil
          wire_messages()
        end)
      end

    assert [[%Message{tags: %{"label" => "one"}}], [%Message{tags: %{"label" => "two"}}]] =
             Enum.map(tasks, &Task.await/1)

    assert ResponseContext.current() == nil
    assert wire_messages() == []
  end

  test "another user's self delivery does not satisfy the command's response" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])
    other = build(:user)

    ResponseContext.with_command(user, Message.parse!("@label=pending PING :probe"), fn ->
      message = %Message{command: "NOTICE", params: [other.nick], trailing: "unrelated"}
      Dispatcher.broadcast_with_echo(message, other, other)
    end)

    assert [%Message{command: "ACK", tags: %{"label" => "pending"}}] = wire_messages()
  end

  test "manual batches fall back to ordinary messages without negotiated support" do
    user = build(:user, pid: self(), capabilities: [])

    ResponseContext.with_command(user, Message.parse!("PING :probe"), fn ->
      ResponseContext.with_batch("example.test/history", fn ->
        Dispatcher.broadcast(%Message{command: "NOTICE", params: [user.nick], trailing: "history"}, :server, user)
      end)
    end)

    assert [%Message{command: "NOTICE", tags: tags, trailing: "history"}] = wire_messages()
    assert tags == %{}
  end

  test "nested command execution restores the outer command's buffered response" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])

    ResponseContext.with_command(user, Message.parse!("@label=outer PING :probe"), fn ->
      # Ending a nonexistent manual batch must not unbalance the event stream.
      ResponseContext.end_batch()
      Dispatcher.broadcast(%Message{command: "NOTICE", params: [user.nick], trailing: "before"}, :server, user)

      Command.dispatch(user, Message.parse!("@label=inner UNKNOWN"))

      Dispatcher.broadcast(%Message{command: "NOTICE", params: [user.nick], trailing: "after"}, :server, user)
    end)

    [inner | outer] = wire_messages()
    assert inner.command == "421"
    assert inner.tags == %{"label" => "inner"}
    assert_batch(outer, "outer")
    assert Enum.map(Enum.slice(outer, 1, 2), & &1.trailing) == ["before", "after"]
    assert ResponseContext.current() == nil
  end

  for count <- [64, 65, 128, 129] do
    test "streams #{count} replies in one labeled response with a bounded buffer" do
      user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])
      count = unquote(count)

      first =
        ResponseContext.with_command(user, Message.parse!("@label=long LIST"), fn ->
          for index <- 1..count do
            Dispatcher.broadcast(
              %Message{command: "NOTICE", params: [], trailing: Integer.to_string(index)},
              :server,
              user
            )

            assert ResponseContext.current().event_count < 64
            assert length(ResponseContext.current().events_rev) < 64
          end

          # Output starts before the handler finishes, including at exact chunk boundaries.
          assert_receive {:broadcast, first}
          assert Message.parse!(first).tags == %{"label" => "long"}
          Message.parse!(first)
        end)

      messages = [first | wire_messages()]
      assert_batch(messages, "long")
      assert Enum.map(Enum.slice(messages, 1, count), & &1.trailing) == Enum.map(1..count, &Integer.to_string/1)
      assert length(messages) == count + 2
      assert ResponseContext.current() == nil
    end
  end

  for label <- [nil, "nested-stream"] do
    @tag response_label: label
    test "streams nested manual batches and automatically closes them with label #{inspect(label)}", %{
      response_label: label
    } do
      user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])
      request = %Message{command: "LIST", params: [], tags: if(label, do: %{"label" => label}, else: %{})}

      ResponseContext.with_command(user, request, fn ->
        ResponseContext.start_batch("example.test/outer")
        ResponseContext.start_batch("example.test/inner")

        for index <- 1..130 do
          Dispatcher.broadcast(
            %Message{command: "NOTICE", params: [], trailing: Integer.to_string(index)},
            :server,
            user
          )
        end
      end)

      messages = wire_messages()
      assert_well_formed_batches(messages, label)

      assert messages |> Enum.filter(&(&1.command == "NOTICE")) |> Enum.map(& &1.trailing) ==
               Enum.map(1..130, &Integer.to_string/1)
    end
  end

  test "closes a streamed manual batch at an exact chunk boundary without an outer label" do
    user = build(:user, pid: self(), capabilities: ["batch"])

    ResponseContext.with_command(user, %Message{command: "LIST", params: []}, fn ->
      ResponseContext.with_batch("example.test/list", fn ->
        for _index <- 1..62 do
          Dispatcher.broadcast(%Message{command: "NOTICE", params: [], trailing: "item"}, :server, user)
        end
      end)
    end)

    messages = wire_messages()
    assert length(messages) == 64
    assert_well_formed_batches(messages, nil)
  end

  test "closes a streamed response when its handler raises at an exact chunk boundary" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])

    assert_raise RuntimeError, "failed after sending", fn ->
      ResponseContext.with_command(user, Message.parse!("@label=failed LIST"), fn ->
        for _index <- 1..64 do
          Dispatcher.broadcast(%Message{command: "NOTICE", params: [], trailing: "item"}, :server, user)
        end

        raise "failed after sending"
      end)
    end

    assert_batch(wire_messages(), "failed")
    assert ResponseContext.current() == nil
  end

  test "flush closes an already streamed response before disconnect" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])

    ResponseContext.with_command(user, Message.parse!("@label=disconnect LIST"), fn ->
      for _index <- 1..65 do
        Dispatcher.broadcast(%Message{command: "NOTICE", params: [], trailing: "item"}, :server, user)
      end

      Dispatcher.disconnect(user, "done")
    end)

    events = output_events()
    assert List.last(events) == {:disconnect, "done"}
    assert_batch(for({:broadcast, wire} <- events, do: Message.parse!(wire)), "disconnect")
  end

  test "nested legacy commands do not inherit an outer response context" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])
    legacy = %{user | capabilities: ["message-tags"]}

    ResponseContext.with_command(user, Message.parse!("@label=outer PING :probe"), fn ->
      ResponseContext.with_command(legacy, %Message{command: "PING", params: []}, fn ->
        assert ResponseContext.current() == nil
        Dispatcher.broadcast(%Message{command: "NOTICE", params: [], trailing: "legacy"}, :server, legacy)
      end)

      assert ResponseContext.current().label == "outer"
    end)

    assert [
             %Message{command: "NOTICE", params: [], tags: %{}},
             %Message{command: "ACK", params: [], tags: %{"label" => "outer"}}
           ] =
             wire_messages()
  end

  test "an empty self broadcast does not suppress the required ACK" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])

    ResponseContext.with_command(user, Message.parse!("@label=empty PING :probe"), fn ->
      Dispatcher.broadcast_with_echo([], user, user)
    end)

    assert [%Message{command: "ACK", params: [], tags: %{"label" => "empty"}}] = wire_messages()
  end

  test "manual batches cannot reopen a flushed response" do
    user = build(:user, pid: self(), capabilities: ["batch", "labeled-response"])

    ResponseContext.with_command(user, Message.parse!("@label=barrier PING :probe"), fn ->
      ResponseContext.flush(user)

      ResponseContext.with_batch("example.test/late", fn ->
        Dispatcher.broadcast(%Message{command: "NOTICE", params: [], trailing: "after"}, :server, user)
      end)
    end)

    assert [%Message{command: "ACK", tags: %{"label" => "barrier"}}, %Message{command: "NOTICE", tags: %{}}] =
             wire_messages()
  end

  @spec assert_well_formed_batches([Message.t()], String.t() | nil) :: :ok
  defp assert_well_formed_batches(messages, label) do
    labels = for %Message{tags: %{"label" => value}} <- messages, do: value
    assert labels == if(label, do: [label], else: [])

    assert [] ==
             Enum.reduce(messages, [], fn message, stack ->
               case message do
                 %Message{command: "BATCH", params: ["+" <> ref, _type]} ->
                   assert message.tags["batch"] == List.first(stack)
                   assert ref =~ ~r/\A[A-Za-z0-9-]+\z/
                   [ref | stack]

                 %Message{command: "BATCH", params: ["-" <> ref]} ->
                   assert [^ref | parent] = stack
                   assert message.tags["batch"] == List.first(parent)
                   parent

                 %Message{} ->
                   assert message.tags["batch"] == List.first(stack)
                   stack
               end
             end)

    :ok
  end

  @spec dispatch(ElixIRCd.Tables.User.t(), String.t()) :: :ok | {:quit, String.t()}
  defp dispatch(user, wire) do
    Memento.transaction!(fn -> Command.dispatch(user, Message.parse!(wire)) end)
  end

  @spec output_events() :: [tuple()]
  defp output_events do
    receive do
      {kind, _payload} = event when kind in [:broadcast, :disconnect] -> [event | output_events()]
    after
      0 -> []
    end
  end

  @spec wire_messages() :: [Message.t()]
  defp wire_messages do
    Enum.map(output_events(), fn {:broadcast, wire} -> Message.parse!(wire) end)
  end

  @spec assert_batch([Message.t()], String.t()) :: :ok
  defp assert_batch([start | rest], label) do
    assert start.command == "BATCH"
    assert ["+" <> ref, "labeled-response"] = start.params
    assert start.tags == %{"label" => label}
    {contents, [finish]} = Enum.split(rest, -1)
    assert Enum.all?(contents, &(&1.tags == %{"batch" => ref}))
    assert finish.command == "BATCH"
    assert finish.params == ["-" <> ref]
    assert finish.tags == %{}
    :ok
  end
end
