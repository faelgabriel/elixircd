defmodule ElixIRCd.TestSupport.NativeS2SDaemon do
  alias ElixIRCd.Commands.Authenticate
  alias ElixIRCd.Commands.Cap
  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Commands.Invite
  alias ElixIRCd.Commands.Chghost
  alias ElixIRCd.Commands.Kick
  alias ElixIRCd.Commands.Kill
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.RateLimiter
  alias ElixIRCd.Server.S2S
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Listener
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.Publication
  alias ElixIRCd.Server.S2S.TLS
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Mnesia

  @shutdown_ms 250
  @clients_key {__MODULE__, :clients}

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    argv = if hd(argv) == "--", do: tl(argv), else: argv

    {options, []} =
      OptionParser.parse!(argv,
        strict: [
          sid: :string,
          port: :integer,
          parent_port: :integer,
          root_port: :integer,
          topology: :string,
          services_authority: :string,
          mnesia_dir: :string,
          certfp: :string,
          certfile: :string,
          keyfile: :string,
          cacertfile: :string,
          peer_certfps: :string,
          sasl_delay_ms: :integer,
          max_connections_per_acceptor: :integer,
          budget: :string,
          timeout: :string
        ]
      )

    sid = Keyword.fetch!(options, :sid)
    port = Keyword.fetch!(options, :port)
    parent_port = Keyword.get(options, :parent_port) || Keyword.get(options, :root_port)
    topology = Keyword.get(options, :topology, "two")
    services_authority = Keyword.get(options, :services_authority)
    mnesia_dir = Keyword.fetch!(options, :mnesia_dir)
    certfp = Keyword.fetch!(options, :certfp)
    certfile = Keyword.fetch!(options, :certfile)
    keyfile = Keyword.fetch!(options, :keyfile)
    cacertfile = Keyword.fetch!(options, :cacertfile)
    peer_certfps = parse_peer_certfps(Keyword.get(options, :peer_certfps, ""))
    sasl_delay_ms = Keyword.get(options, :sasl_delay_ms, 0)

    budget_overrides =
      options
      |> Keyword.take([:max_connections_per_acceptor])
      |> Keyword.merge(parse_budget_overrides(Keyword.get(options, :budget, "")))

    timeout_overrides = parse_timeout_overrides(Keyword.get(options, :timeout, ""))

    Application.ensure_all_started(:crypto)
    Application.ensure_all_started(:public_key)
    Application.ensure_all_started(:ssl)
    Application.put_env(:mnesia, :dir, String.to_charlist(mnesia_dir))
    ElixIRCd.Config.Loader.load!("config/elixircd.exs", :boot)
    services = Application.fetch_env!(:elixircd, :services)
    nickserv = Keyword.put(services[:nickserv] || [], :wait_register_time, 0)
    Application.put_env(:elixircd, :services, Keyword.put(services, :nickserv, nickserv))
    Application.put_env(:elixircd, :cloaking, enabled: false)
    Application.put_env(:elixircd, :settings, case_mapping: :ascii, utf8_only: true)
    Application.put_env(:elixircd, :sasl, put_in(Application.fetch_env!(:elixircd, :sasl), [:ecdsa, :enabled], true))

    Mnesia.setup_mnesia(recreate: true)
    {:ok, _rate_limiter} = RateLimiter.start_link([])

    config =
      config(
        sid,
        port,
        parent_port,
        topology,
        services_authority,
        certfp,
        certfile,
        keyfile,
        cacertfile,
        peer_certfps,
        budget_overrides,
        timeout_overrides
      )

    Application.put_env(:elixircd, :s2s, config[:s2s])

    {:ok, _dynamic_supervisor} =
      DynamicSupervisor.start_link(strategy: :one_for_one, name: S2S.ConnectorSupervisor)

    manager_options =
      [config: config, name: Manager]
      |> maybe_add_sasl_delay(sasl_delay_ms)

    {:ok, manager} = Manager.start_link(manager_options)

    Process.unlink(manager)
    manager_monitor = Process.monitor(manager)

    listener_options =
      TLS.listener_options(config[:s2s])
      |> Keyword.merge(
        handler_module: Listener,
        handler_options: %{manager: Manager, config: config},
        num_acceptors: 1,
        num_connections: max_connections_per_acceptor(config),
        read_timeout: :infinity,
        shutdown_timeout: 2_000
      )

    {:ok, listener} = ThousandIsland.start_link(listener_options)
    {:ok, {_address, actual_port}} = ThousandIsland.listener_info(listener)

    IO.puts("READY #{sid} #{actual_port}")
    command_loop(manager, listener, manager_monitor)
  rescue
    error ->
      IO.puts(:stderr, "DAEMON_ERROR #{Exception.format(:error, error, __STACKTRACE__)}")
      System.halt(1)
  end

  defp maybe_add_sasl_delay(options, delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    authority_options = ElixIRCd.Server.S2S.RemoteSASL.authority_options()
    plain_lookup = Keyword.fetch!(authority_options, :plain_lookup)

    delayed_plain_lookup = fn username, password, client_info ->
      Process.sleep(delay_ms)
      plain_lookup.(username, password, client_info)
    end

    Keyword.put(options, :sasl_options, Keyword.put(authority_options, :plain_lookup, delayed_plain_lookup))
  end

  defp maybe_add_sasl_delay(options, _delay_ms), do: options

  defp command_loop(manager, listener, manager_monitor) do
    case IO.gets("") do
      :eof ->
        stop_components(manager, listener)
        System.halt(0)

      "status\n" ->
        status(manager, manager_monitor)
        command_loop(manager, listener, manager_monitor)

      "manager_suspend\n" ->
        :ok = :sys.suspend(manager)
        IO.puts("MANAGER_SUSPENDED")
        command_loop(manager, listener, manager_monitor)

      "manager_resume\n" ->
        try do
          case :sys.resume(manager) do
            :ok -> :ok
            {:error, _reason} -> :ok
          end
        catch
          :exit, _reason -> :ok
        end

        IO.puts("MANAGER_RESUMED")
        command_loop(manager, listener, manager_monitor)

      "manager_queue\n" ->
        {:message_queue_len, queue_length} = Process.info(manager, :message_queue_len)
        IO.puts("MANAGER_QUEUE #{queue_length}")
        command_loop(manager, listener, manager_monitor)

      "global_counts\n" ->
        global_counts()
        command_loop(manager, listener, manager_monitor)

      "policy_nick " <> rest ->
        policy_nick(manager, String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "metrics\n" ->
        metrics()
        command_loop(manager, listener, manager_monitor)

      "add_user " <> rest ->
        nick = String.trim(rest)
        add_user(manager, nick)
        command_loop(manager, listener, manager_monitor)

      "seed_account " <> rest ->
        seed_account(manager, String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "seed_registered_channel " <> rest ->
        seed_registered_channel(manager, String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "add_client " <> rest ->
        nick = String.trim(rest)
        add_client(manager, nick)
        command_loop(manager, listener, manager_monitor)

      "client_command " <> rest ->
        client_command(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "client_command_async " <> rest ->
        client_command_async(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "restrict_client " <> rest ->
        restrict_client(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "add_pending_client " <> rest ->
        nick = String.trim(rest)
        add_pending_client(manager, nick)
        command_loop(manager, listener, manager_monitor)

      "complete_client " <> rest ->
        complete_client(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "client_auth " <> rest ->
        client_auth(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "disconnect_client " <> rest ->
        disconnect_client(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "client_capabilities " <> rest ->
        client_capabilities(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "create_channel " <> rest ->
        name = String.trim(rest)
        create_channel(name)
        command_loop(manager, listener, manager_monitor)

      "join_client " <> rest ->
        join_client(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "kick_client " <> rest ->
        kick_client(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "invite_client " <> rest ->
        invite_client(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "chghost_client " <> rest ->
        chghost_client(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "kill_client " <> rest ->
        kill_client(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "make_oper " <> rest ->
        make_oper(String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "user_info " <> rest ->
        user_info(manager, String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "send_user " <> rest ->
        send_user(manager, String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "send_channel " <> rest ->
        send_channel(manager, String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "read_message\n" ->
        read_message()
        command_loop(manager, listener, manager_monitor)

      "request_query " <> rest ->
        request_query(manager, String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "request_service " <> rest ->
        request_service(manager, String.trim(rest))
        command_loop(manager, listener, manager_monitor)

      "stop\n" ->
        stop_components(manager, listener)
        IO.puts("STOPPED")
        System.halt(0)

      _line ->
        IO.puts("ERROR unknown_command")
        command_loop(manager, listener, manager_monitor)
    end
  end

  defp status(manager, manager_monitor) do
    status = Manager.status(manager)
    runtime = Manager.runtime_view(manager)

    IO.puts(
      "STATUS " <>
        inspect(
          %{
            sid: status.sid,
            parent_sid: status.parent_sid,
            lifecycle: status.lifecycle,
            reachable_sids: status.reachable_sids,
            sessions: status.sessions,
            connector_error: status.connector_error,
            last_link_error: status.last_link_error,
            retry_blocked: status.retry_blocked?,
            users: map_size(runtime.users),
            channels: map_size(runtime.channels),
            memberships: map_size(runtime.memberships),
            pending_requests: status.pending_requests,
            pending_request_methods: status.pending_request_methods,
            pending_repairs: status.pending_repairs,
            pending_policy_repairs: status.pending_policy_repairs,
            pending_link_frames: status.pending_link_frames,
            pending_link_bytes: status.pending_link_bytes,
            pending_sync_frames: status.pending_sync_frames,
            pending_sync_bytes: status.pending_sync_bytes,
            pending_sasl_attempts: status.pending_sasl_attempts,
            pending_sasl_jobs: status.pending_sasl_jobs,
            policy_revision: status.policy_revision,
            policy_ready: Policy.grant_ready?(runtime.policy),
            services_authority: status.services_authority,
            local_memberships: local_membership_count()
          },
          limit: :infinity
        )
    )
  rescue
    error ->
      IO.puts("STATUS_ERROR #{inspect(error)}")
  catch
    :exit, reason ->
      IO.puts("STATUS %{manager_exit: #{inspect(reason)}}")
      Process.sleep(100)

      receive do
        {:DOWN, ^manager_monitor, :process, _pid, monitor_reason} ->
          IO.puts("MANAGER_DOWN #{inspect(monitor_reason)}")
      after
        0 -> :ok
      end
  end

  defp global_counts do
    counts =
      Memento.transaction!(fn ->
        %{
          registered_nicks: length(RegisteredNicks.get_all()),
          registered_channels: length(RegisteredChannels.get_all()),
          memos: :mnesia.table_info(ElixIRCd.Tables.Memo, :size)
        }
      end)

    IO.puts("GLOBAL_COUNTS " <> inspect(counts, limit: :infinity))
  rescue
    error -> IO.puts("GLOBAL_COUNTS_ERROR #{inspect(error)}")
  end

  defp policy_nick(manager, nickname) when is_binary(nickname) and nickname != "" do
    runtime = Manager.runtime_view(manager)
    key = ElixIRCd.Utils.CaseMapping.normalize(nickname, runtime.case_mapping)

    case Policy.get(runtime.policy, "nick", key) do
      {:ok, nick} ->
        account =
          case Policy.get(runtime.policy, "account", nick["account_id"]) do
            {:ok, value} -> value
            :not_found -> nil
          end

        IO.puts(
          "POLICY_NICK #{inspect(%{nickname: nick["nickname"], account_id: nick["account_id"], canonical_name: account && account["canonical_name"], reserved_until_ms: nick["reserved_until_ms"]})}"
        )

      :not_found ->
        IO.puts("POLICY_NICK %{error: :not_found}")
    end
  rescue
    _ -> IO.puts("POLICY_NICK %{error: :unavailable}")
  end

  defp policy_nick(_manager, _nickname), do: IO.puts("POLICY_NICK %{error: :invalid_nickname}")

  defp metrics do
    IO.puts(
      "METRICS " <>
        inspect(
          %{
            memory_bytes: :erlang.memory(:total),
            process_count: :erlang.system_info(:process_count),
            run_queue: :erlang.statistics(:run_queue),
            schedulers_online: :erlang.system_info(:schedulers_online)
          },
          limit: :infinity
        )
    )
  end

  defp add_user(manager, nick) when is_binary(nick) and byte_size(nick) > 0 do
    boot = Manager.status(manager).boot

    user =
      Output.transaction(
        fn ->
          user =
            ElixIRCd.Factory.build(:user,
              pid: nil,
              nick: nick,
              home_sid: Manager.status(manager).sid,
              home_boot: boot
            )

          Memento.Query.write(user)
          Publication.user_changed(user)
          user
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    IO.puts("USER #{user.uid}")
  rescue
    error ->
      IO.puts("USER_ERROR #{inspect(error)}")
  end

  defp add_user(_manager, _nick), do: IO.puts("USER_ERROR invalid_nick")

  defp seed_account(manager, arguments) do
    case String.split(arguments, " ", parts: 3, trim: true) do
      [nickname, password | public_key] when nickname != "" and password != "" and length(public_key) in [0, 1] ->
        attrs = %{
          nickname: nickname,
          password_hash: Argon2.hash_pwd_salt(password),
          email: "native-s2s@example.test",
          registered_by: "native-s2s@test",
          verified_at: DateTime.utc_now()
        }

        attrs =
          case public_key do
            [encoded] when encoded != "" -> Map.put(attrs, :settings, Settings.new(%{pubkey: encoded}))
            _ -> attrs
          end

        account =
          Output.transaction(
            fn ->
              RegisteredNicks.create(attrs)
            end,
            drain_fun: &Dispatcher.drain_intent/1
          )

        :ok = Manager.refresh_policy(manager)
        IO.puts("ACCOUNT #{account.nickname}")

      _ ->
        IO.puts("ACCOUNT_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("ACCOUNT_ERROR #{inspect(error)}")
  end

  defp seed_registered_channel(manager, arguments) do
    case String.split(arguments, " ", parts: 2, trim: true) do
      [name, founder] when name != "" and founder != "" ->
        registered_channel =
          Output.transaction(
            fn ->
              RegisteredChannels.create(%{
                name: name,
                founder: founder,
                password_hash: Argon2.hash_pwd_salt("native-channel-password"),
                registered_by: founder
              })
            end,
            drain_fun: &Dispatcher.drain_intent/1
          )

        :ok = Manager.refresh_policy(manager)
        IO.puts("REGISTERED_CHANNEL #{registered_channel.name}")

      _ ->
        IO.puts("REGISTERED_CHANNEL_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("REGISTERED_CHANNEL_ERROR #{inspect(error)}")
  end

  defp add_client(manager, nick) when is_binary(nick) and byte_size(nick) > 0 do
    boot = Manager.status(manager).boot
    uid = Identity.uid()
    parent = self()
    client_pid = spawn(fn -> client_proxy(parent, uid) end)

    put_clients(Map.put(clients(), uid, client_pid))

    user =
      Output.transaction(
        fn ->
          user =
            ElixIRCd.Factory.build(:user,
              uid: uid,
              pid: client_pid,
              nick: nick,
              home_sid: Manager.status(manager).sid,
              home_boot: boot,
              transport: :tls,
              capabilities: ["sasl", "message-tags", "invite-notify"],
              cap_version: 302
            )

          Memento.Query.write(user)
          Publication.user_changed(user)
          user
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    IO.puts("CLIENT #{user.uid}")
  rescue
    error -> IO.puts("CLIENT_ERROR #{inspect(error)}")
  end

  defp add_client(_manager, _nick), do: IO.puts("CLIENT_ERROR invalid_nick")

  defp client_command(arguments) do
    case String.split(arguments, " ", parts: 2, trim: true) do
      [uid, command] when uid != "" and command != "" ->
        case clients()[uid] do
          pid when is_pid(pid) ->
            wire = if String.ends_with?(command, "\r\n"), do: command, else: command <> "\r\n"
            result = Connection.handle_receive(pid, wire)
            IO.puts("CLIENT_COMMAND #{inspect(result)}")

          _ ->
            IO.puts("CLIENT_COMMAND_ERROR client_not_found")
        end

      _ ->
        IO.puts("CLIENT_COMMAND_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("CLIENT_COMMAND_ERROR #{inspect(error)}")
  end

  defp client_command_async(arguments) do
    case String.split(arguments, " ", parts: 2, trim: true) do
      [uid, command] when uid != "" and command != "" ->
        case clients()[uid] do
          pid when is_pid(pid) ->
            wire = if String.ends_with?(command, "\r\n"), do: command, else: command <> "\r\n"
            send(pid, {:client_command, wire})
            IO.puts("CLIENT_COMMAND_ASYNC #{uid}")

          _ ->
            IO.puts("CLIENT_COMMAND_ASYNC_ERROR client_not_found")
        end

      _ ->
        IO.puts("CLIENT_COMMAND_ASYNC_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("CLIENT_COMMAND_ASYNC_ERROR #{inspect(error)}")
  end

  defp restrict_client(nick) when is_binary(nick) and nick != "" do
    result =
      Output.transaction(
        fn ->
          with {:ok, user} <- Users.get_by_nick(nick),
               updated = Users.update(user, %{modes: Enum.uniq([:R | user.modes])}),
               Memento.Query.write(updated),
               Publication.user_changed(updated) do
            updated
          end
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    IO.puts("RESTRICTED #{result.nick}")
  rescue
    error -> IO.puts("RESTRICT_ERROR #{inspect(error)}")
  end

  defp restrict_client(_nick), do: IO.puts("RESTRICT_ERROR invalid_nick")

  defp add_pending_client(manager, nick) when is_binary(nick) and byte_size(nick) > 0 do
    boot = Manager.status(manager).boot
    uid = Identity.uid()
    parent = self()
    client_pid = spawn(fn -> client_proxy(parent, uid) end)

    put_clients(Map.put(clients(), uid, client_pid))

    user =
      Output.transaction(
        fn ->
          user =
            ElixIRCd.Factory.build(:user,
              uid: uid,
              pid: client_pid,
              nick: nick,
              home_sid: Manager.status(manager).sid,
              home_boot: boot,
              transport: :tls,
              registered: false,
              ident: nil,
              realname: nil,
              capabilities: ["sasl"],
              cap_version: 302,
              cap_negotiating: true
            )

          Memento.Query.write(user)
          Publication.user_changed(user)
          user
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    IO.puts("PENDING_CLIENT #{user.uid}")
  rescue
    error -> IO.puts("PENDING_CLIENT_ERROR #{inspect(error)}")
  end

  defp add_pending_client(_manager, _nick), do: IO.puts("PENDING_CLIENT_ERROR invalid_nick")

  defp complete_client(uid) when is_binary(uid) and uid != "" do
    result =
      Output.transaction(
        fn ->
          with {:ok, user} <- Users.get_by_uid(uid),
               _updated <-
                 Users.update(user, %{
                   ident: "pending",
                   realname: "Pending client",
                   cap_negotiating: false,
                   registered: true,
                   registered_at: DateTime.utc_now()
                 }) do
            :ok
          else
            _ -> {:error, :client_not_found}
          end
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    IO.puts("COMPLETED #{uid} #{inspect(result)}")
  rescue
    error -> IO.puts("COMPLETED_ERROR #{inspect(error)}")
  end

  defp complete_client(_uid), do: IO.puts("COMPLETED_ERROR invalid_uid")

  defp client_auth(arguments) do
    case String.split(arguments, " ", parts: 2, trim: true) do
      [uid, command] when uid != "" and command != "" ->
        case clients()[uid] do
          pid when is_pid(pid) ->
            _ =
              Output.transaction(
                fn ->
                  with {:ok, user} <- Users.get_by_uid(uid),
                       {:ok, message} <- Message.parse(command <> "\r\n") do
                    Authenticate.handle(user, message)
                  end
                end,
                drain_fun: &Dispatcher.drain_intent/1
              )

            IO.puts("AUTH_SENT #{uid}")

          _ ->
            IO.puts("AUTH_ERROR client_not_found")
        end

      _ ->
        IO.puts("AUTH_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("AUTH_ERROR #{inspect(error)}")
  end

  defp disconnect_client(uid) when is_binary(uid) and uid != "" do
    case clients()[uid] do
      pid when is_pid(pid) ->
        :ok = Connection.handle_disconnect(pid, :tls, "test disconnect")
        IO.puts("CLIENT_DISCONNECTED #{uid}")

      _ ->
        IO.puts("DISCONNECT_ERROR client_not_found")
    end
  rescue
    error -> IO.puts("DISCONNECT_ERROR #{inspect(error)}")
  end

  defp disconnect_client(_uid), do: IO.puts("DISCONNECT_ERROR invalid_uid")

  defp client_capabilities(uid) when is_binary(uid) and uid != "" do
    case Memento.transaction!(fn -> Users.get_by_uid(uid) end) do
      {:ok, user} -> IO.puts("CAPABILITIES #{Cap.get_capabilities_list(user)}")
      _ -> IO.puts("CAPABILITIES_ERROR client_not_found")
    end
  rescue
    error -> IO.puts("CAPABILITIES_ERROR #{inspect(error)}")
  end

  defp client_capabilities(_uid), do: IO.puts("CAPABILITIES_ERROR invalid_uid")

  defp create_channel(name) when is_binary(name) and byte_size(name) > 0 do
    channel =
      Output.transaction(
        fn ->
          channel = Channels.create(%{name: name, topic: nil})
          channel
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    IO.puts("CHANNEL #{channel.name} #{channel.cid}")
  rescue
    error -> IO.puts("CHANNEL_ERROR #{inspect(error)}")
  end

  defp create_channel(_name), do: IO.puts("CHANNEL_ERROR invalid_name")

  defp join_client(arguments) do
    case String.split(arguments, " ", parts: 2) do
      [nick, channel_name] ->
        result =
          Output.transaction(
            fn ->
              with {:ok, user} <- Users.get_by_nick(nick) do
                Join.handle(user, %Message{command: "JOIN", params: [channel_name]})
              else
                _ -> :user_not_found
              end
            end,
            drain_fun: &Dispatcher.drain_intent/1
          )

        joined? =
          Memento.transaction!(fn ->
            with {:ok, user} <- Users.get_by_nick(nick),
                 {:ok, _membership} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name) do
              true
            else
              _ -> false
            end
          end)

        IO.puts("JOINED #{nick} #{channel_name} #{inspect({result, joined?})}")

      _ ->
        IO.puts("JOIN_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("JOIN_ERROR #{inspect(error)}")
  end

  defp kick_client(arguments) do
    case String.split(arguments, " ", parts: 4, trim: true) do
      [actor_nick, channel_name, target_nick] ->
        kick_client(actor_nick, channel_name, target_nick, nil)

      [actor_nick, channel_name, target_nick, reason] ->
        kick_client(actor_nick, channel_name, target_nick, reason)

      _ ->
        IO.puts("KICK_ERROR invalid_arguments")
    end
  end

  defp kick_client(actor_nick, channel_name, target_nick, reason) do
    result =
      Output.transaction(
        fn ->
          with {:ok, user} <- Users.get_by_nick(actor_nick) do
            result =
              Kick.handle(user, %Message{
                command: "KICK",
                params: [channel_name, target_nick],
                trailing: reason
              })

            {result, user.uid}
          else
            _ -> :user_not_found
          end
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    reply = if match?({:ok, _uid}, result), do: await_action_reply(elem(result, 1)), else: nil

    IO.puts("KICKED #{inspect({result, reply})}")
  rescue
    error -> IO.puts("KICK_ERROR #{inspect(error)}")
  end

  defp invite_client(arguments) do
    case String.split(arguments, " ", parts: 4, trim: true) do
      [actor_nick, channel_name, target_nick] ->
        result =
          Output.transaction(
            fn ->
              with {:ok, user} <- Users.get_by_nick(actor_nick) do
                invite_result =
                  Invite.handle(user, %Message{
                    command: "INVITE",
                    params: [target_nick, channel_name],
                    tags: %{}
                  })

                {invite_result, user.uid}
              else
                _ -> :user_not_found
              end
            end,
            drain_fun: &Dispatcher.drain_intent/1
          )

        reply = if match?({:ok, _uid}, result), do: await_action_reply(elem(result, 1)), else: nil
        IO.puts("INVITED #{inspect({result, reply})}")

      _ ->
        IO.puts("INVITE_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("INVITE_ERROR #{inspect(error)}")
  end

  defp chghost_client(arguments) do
    case String.split(arguments, " ", parts: 4, trim: true) do
      [operator_nick, target_nick, new_ident, new_host] ->
        result =
          Output.transaction(
            fn ->
              with {:ok, operator} <- Users.get_by_nick(operator_nick) do
                Chghost.handle(operator, %Message{
                  command: "CHGHOST",
                  params: [target_nick, new_ident, new_host],
                  tags: %{}
                })

                operator.uid
              else
                _ -> :user_not_found
              end
            end,
            drain_fun: &Dispatcher.drain_intent/1
          )

        reply = if is_binary(result), do: await_action_reply(result), else: nil
        IO.puts("CHGHOSTED #{inspect({result, reply})}")

      _ ->
        IO.puts("CHGHOST_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("CHGHOST_ERROR #{inspect(error)}")
  end

  defp kill_client(arguments) do
    case String.split(arguments, " ", parts: 3, trim: true) do
      [operator_nick, target_nick | reason] ->
        result =
          Output.transaction(
            fn ->
              with {:ok, operator} <- Users.get_by_nick(operator_nick) do
                Kill.handle(operator, %Message{
                  command: "KILL",
                  params: [target_nick],
                  trailing: List.first(reason),
                  tags: %{}
                })

                operator.uid
              else
                _ -> :user_not_found
              end
            end,
            drain_fun: &Dispatcher.drain_intent/1
          )

        reply = if is_binary(result), do: await_action_reply(result), else: nil
        IO.puts("KILLED #{inspect({result, reply})}")

      _ ->
        IO.puts("KILL_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("KILL_ERROR #{inspect(error)}")
  end

  defp make_oper(nick) when is_binary(nick) and byte_size(nick) > 0 do
    result =
      Output.transaction(
        fn ->
          with {:ok, user} <- Users.get_by_nick(nick) do
            updated = Users.update(user, %{modes: Enum.uniq([:o | user.modes])})
            updated.uid
          else
            _ -> :user_not_found
          end
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    IO.puts("OPER #{inspect(result)}")
  rescue
    error -> IO.puts("OPER_ERROR #{inspect(error)}")
  end

  defp make_oper(_nick), do: IO.puts("OPER_ERROR invalid_nick")

  defp user_info(manager, nick) when is_binary(nick) and byte_size(nick) > 0 do
    local_result = Memento.transaction!(fn -> Users.get_by_nick(nick) end)

    result =
      case local_result do
        {:ok, user} ->
          {:ok, user_info_fields(user)}

        error ->
          case View.user_by_nick(Manager.runtime_view(manager), nick) do
            {:ok, _uid, projected} -> {:ok, user_info_fields(projected)}
            _ -> error
          end
      end

    IO.puts("USER_INFO #{inspect(result, limit: :infinity)}")
  rescue
    error -> IO.puts("USER_INFO_ERROR #{inspect(error)}")
  end

  defp user_info(_manager, _nick), do: IO.puts("USER_INFO_ERROR invalid_nick")

  defp user_info_fields(user),
    do:
      Map.take(user, [
        :uid,
        :pid,
        :nick,
        :hostname,
        :cloaked_hostname,
        :ident,
        :identified_as,
        :owner_rev,
        :modes,
        :home_sid,
        :home_boot
      ])

  defp await_action_reply(uid) when is_binary(uid) do
    receive do
      {:s2s_reply, ^uid, _request_id, result, _context} -> result
    after
      4_000 -> :timeout
    end
  end

  defp send_user(manager, arguments) do
    case String.split(arguments, " ", parts: 3) do
      [actor_uid, target_uid, text] when text != "" ->
        result = Manager.publish_message(manager, actor_uid, %{"user" => target_uid}, "PRIVMSG", text, %{})
        IO.puts("SENT #{inspect(result)}")

      _ ->
        IO.puts("SEND_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("SEND_ERROR #{inspect(error)}")
  end

  defp send_channel(manager, arguments) do
    case String.split(arguments, " ", parts: 3) do
      [actor_uid, channel_name, text] when text != "" ->
        result =
          with {:ok, runtime} <- View.runtime(manager),
               {:ok, _channel, projected} <- View.channel(runtime, channel_name) do
            publish_result =
              Manager.publish_message(
                manager,
                actor_uid,
                %{"channel" => projected.ref, "minimum_status" => nil},
                "PRIVMSG",
                text,
                %{}
              )

            publish_result
          end

        IO.puts("SENT #{inspect(result)}")

      _ ->
        IO.puts("SEND_ERROR invalid_arguments")
    end
  rescue
    error -> IO.puts("SEND_ERROR #{inspect(error)}")
  end

  defp read_message do
    messages = drain_messages([])
    IO.puts("MESSAGE #{inspect(messages, binaries: :as_strings, limit: :infinity)}")
  end

  defp request_query(manager, arguments) do
    case String.split(arguments, " ", parts: 2, trim: true) do
      [uid, command_and_params] when uid != "" and command_and_params != "" ->
        [command | params] = String.split(command_and_params, " ", trim: true)

        request_remote(
          manager,
          uid,
          "query",
          %{
            "command" => command,
            "params" => params,
            "target_uid" => nil,
            "view" => "client"
          },
          "QUERY_REPLY"
        )

      _ ->
        IO.puts("REQUEST_ERROR invalid_query_arguments")
    end
  end

  defp request_service(manager, arguments) do
    case String.split(arguments, " ", parts: 3, trim: true) do
      [uid, service, command_and_args] when uid != "" and service != "" and command_and_args != "" ->
        request_remote(
          manager,
          uid,
          "service",
          %{
            "service" => service,
            "arguments" => String.split(command_and_args, " ", trim: true),
            "scope" => "global",
            "channel" => nil
          },
          "SERVICE_REPLY"
        )

      _ ->
        IO.puts("REQUEST_ERROR invalid_service_arguments")
    end
  end

  defp request_remote(manager, uid, method, args, output_prefix) do
    case Manager.status(manager).services_authority do
      authority when is_binary(authority) ->
        case Manager.request_with_reply_context(
               manager,
               authority,
               %{"user" => uid},
               method,
               args,
               empty_request_guards(),
               self(),
               uid,
               %{}
             ) do
          {:ok, request_id} -> await_request_replies(uid, request_id, output_prefix, [])
          {:error, reason} -> IO.puts("REQUEST_ERROR #{inspect(reason)}")
        end

      _ ->
        IO.puts("REQUEST_ERROR services_authority_missing")
    end
  rescue
    error -> IO.puts("REQUEST_ERROR #{inspect(error)}")
  end

  defp await_request_replies(uid, request_id, output_prefix, replies) do
    receive do
      {:s2s_reply, ^uid, ^request_id, result, _context} ->
        replies = [result | replies]

        if result[:done] == true do
          IO.puts("#{output_prefix} #{inspect(Enum.reverse(replies), limit: :infinity)}")
        else
          await_request_replies(uid, request_id, output_prefix, replies)
        end
    after
      6_000 ->
        IO.puts("REQUEST_ERROR timeout")
    end
  end

  defp empty_request_guards do
    %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }
  end

  defp drain_messages(messages) do
    receive do
      {:broadcast, data} when is_binary(data) ->
        drain_messages([data | messages])

      {:native_s2s_client_message, uid, data} when is_binary(uid) and is_binary(data) ->
        drain_messages([data | messages])

      {:native_s2s_client_disconnect, uid, reason} when is_binary(uid) ->
        drain_messages(["DISCONNECT #{uid} #{reason}" | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp local_membership_count do
    Memento.transaction!(fn -> Memento.Query.all(UserChannel) |> length() end)
  rescue
    _ -> 0
  end

  defp clients, do: Process.get(@clients_key, %{})

  defp put_clients(value) when is_map(value), do: Process.put(@clients_key, value)

  defp client_proxy(parent, uid) do
    receive do
      {:client_command, wire} when is_binary(wire) ->
        _ = Connection.handle_receive(self(), wire)
        client_proxy(parent, uid)

      {:broadcast, data} when is_binary(data) ->
        send(parent, {:native_s2s_client_message, uid, data})
        client_proxy(parent, uid)

      {:disconnect, reason} ->
        send(parent, {:native_s2s_client_disconnect, uid, reason})

      {:disconnect, ^uid, reason} ->
        send(parent, {:native_s2s_client_disconnect, uid, reason})

      {:s2s_reply, reply_uid, request_id, result, context} ->
        Connection.handle_s2s_reply(self(), reply_uid, request_id, result, context)
        client_proxy(parent, uid)

      {:s2s_reply, reply_uid, result} ->
        Connection.handle_s2s_reply(self(), reply_uid, result)
        client_proxy(parent, uid)

      :stop ->
        :ok

      _message ->
        client_proxy(parent, uid)
    end
  end

  defp stop_components(manager, listener) do
    if is_pid(manager) and Process.alive?(manager), do: Manager.shutdown(manager)
    if is_pid(listener) and Process.alive?(listener), do: ThousandIsland.stop(listener, 1_000)
    Enum.each(clients(), fn {_uid, pid} -> if is_pid(pid), do: send(pid, :stop) end)
    put_clients(%{})
    wait_for_exit(manager, 100)
    if is_pid(Process.whereis(S2S.ConnectorSupervisor)), do: Supervisor.stop(S2S.ConnectorSupervisor, :normal, 1_000)
    if Process.whereis(:mnesia), do: Memento.stop()
  catch
    :exit, _ -> :ok
  end

  defp wait_for_exit(pid, 0) when is_pid(pid), do: :ok

  defp wait_for_exit(pid, attempts) when is_pid(pid) and attempts > 0 do
    if Process.alive?(pid) do
      Process.sleep(10)
      wait_for_exit(pid, attempts - 1)
    else
      :ok
    end
  end

  defp wait_for_exit(_pid, _attempts), do: :ok

  defp config(
         sid,
         port,
         parent_port,
         topology,
         services_authority,
         certfp,
         certfile,
         keyfile,
         cacertfile,
         peer_certfps,
         budget_overrides,
         timeout_overrides
       ) do
    topology = topology(topology)
    parent_sid = topology[sid].parent

    base_config(
      sid,
      port,
      parent_sid,
      parent_port,
      topology,
      services_authority,
      certfp,
      certfile,
      keyfile,
      cacertfile,
      peer_certfps,
      budget_overrides,
      timeout_overrides
    )
  end

  defp topology("two") do
    %{
      "root" => %{parent: nil, children: ["leaf"]},
      "leaf" => %{parent: "root", children: []}
    }
  end

  defp topology("three") do
    %{
      "root" => %{parent: nil, children: ["middle"]},
      "middle" => %{parent: "root", children: ["leaf"]},
      "leaf" => %{parent: "middle", children: []}
    }
  end

  defp topology("star") do
    %{
      "root" => %{parent: nil, children: ["left", "right"]},
      "left" => %{parent: "root", children: []},
      "right" => %{parent: "root", children: []}
    }
  end

  defp topology("balanced") do
    %{
      "root" => %{parent: nil, children: ["branch-a", "branch-b"]},
      "branch-a" => %{parent: "root", children: ["leaf-a"]},
      "branch-b" => %{parent: "root", children: ["leaf-b"]},
      "leaf-a" => %{parent: "branch-a", children: []},
      "leaf-b" => %{parent: "branch-b", children: []}
    }
  end

  defp topology("fanout") do
    children = Enum.map(1..12, &"leaf#{&1}")

    Map.new(
      [{"root", %{parent: nil, children: children}}] ++
        Enum.map(children, &{&1, %{parent: "root", children: []}})
    )
  end

  defp topology(value), do: raise(ArgumentError, "unknown native S2S test topology #{inspect(value)}")

  defp base_config(
         sid,
         port,
         parent_sid,
         parent_port,
         topology,
         services_authority,
         certfp,
         certfile,
         keyfile,
         cacertfile,
         peer_certfps,
         budget_overrides,
         timeout_overrides
       ) do
    roster =
      topology
      |> Enum.map(fn {node_sid, node} ->
        [sid: node_sid, name: node_sid <> ".example.test", parent: node.parent]
      end)
      |> Enum.sort_by(&Keyword.fetch!(&1, :sid))

    children =
      topology[sid].children
      |> Map.new(fn child_sid ->
        {child_sid, [pins: peer_pins(peer_certfps, child_sid, certfp), ips: []]}
      end)

    [
      server: [hostname: sid <> ".example.test"],
      settings: [case_mapping: :ascii, utf8_only: true],
      s2s: [
        enabled: true,
        network_id: "native-s2s-process-test",
        semantic_revision: 1,
        server_id: sid,
        server_name: sid <> ".example.test",
        services_authority: services_authority,
        roster: roster,
        listener: [
          ip: {127, 0, 0, 1},
          port: port,
          certfile: certfile,
          keyfile: keyfile,
          cacertfile: cacertfile,
          versions: [:"tlsv1.2", :"tlsv1.3"]
        ],
        children: children,
        parent_connection:
          if(parent_sid && is_integer(parent_port),
            do: [
              address: "localhost",
              port: parent_port,
              sni: "localhost",
              pins: peer_pins(peer_certfps, parent_sid, certfp)
            ],
            else: nil
          ),
        budgets:
          Keyword.merge(
            [
              max_frame_bytes: 1_048_576,
              max_inbound_queue_bytes: 2 * 1_048_576,
              per_link_queue_bytes: 16 * 1_048_576,
              snapshot_delta_queue_bytes: 16 * 1_048_576,
              aggregate_output_bytes: 128 * 1_048_576,
              aggregate_pending_frames: 262_144,
              aggregate_pending_bytes: 128 * 1_048_576,
              snapshot_staging_bytes: 128 * 1_048_576,
              max_pending_requests_origin: 128,
              max_pending_requests_node: 1_024,
              sasl_workers: 2,
              max_pending_frames: 65_536,
              max_stream_parts: 4_096,
              max_stream_bytes: 16 * 1_048_576,
              max_repairs: 16,
              max_list_slots: 4_096,
              max_memberships: 20,
              max_policy_objects: 65_536
            ],
            budget_overrides
          ),
        timeouts:
          Keyword.merge(
            [
              tls_hello_ms: 5_000,
              incomplete_frame_ms: 5_000,
              snapshot_ms: 10_000,
              request_ms: 5_000,
              heartbeat_ms: 60_000,
              heartbeat_timeout_ms: 60_000,
              shutdown_ms: @shutdown_ms
            ],
            timeout_overrides
          ),
        reconnect: [initial_ms: 100, max_ms: 500, jitter_ms: 0, stable_ms: 100]
      ]
    ]
  end

  defp parse_peer_certfps(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [sid, certfps] when sid != "" and certfps != "" ->
          pins = String.split(certfps, "|", trim: true)
          {sid, if(length(pins) == 1, do: hd(pins), else: pins)}

        _ ->
          raise ArgumentError, "invalid peer certificate fingerprint #{inspect(pair)}"
      end
    end)
  end

  defp peer_pins(peer_certfps, sid, default) do
    case Map.get(peer_certfps, sid, default) do
      pins when is_list(pins) -> pins
      pin -> [pin]
    end
  end

  defp max_connections_per_acceptor(config) do
    config
    |> Keyword.get(:s2s, [])
    |> Keyword.get(:budgets, [])
    |> Keyword.get(:max_connections_per_acceptor, 256)
  end

  @budget_keys [
    :aggregate_output_bytes,
    :aggregate_pending_bytes,
    :aggregate_pending_frames,
    :max_connections_per_acceptor,
    :max_frame_bytes,
    :max_inbound_queue_bytes,
    :max_list_slots,
    :max_memberships,
    :max_pending_frames,
    :max_pending_requests_node,
    :max_pending_requests_origin,
    :max_policy_objects,
    :max_repairs,
    :max_snapshot_delta_rows,
    :max_stream_bytes,
    :max_stream_parts,
    :per_link_queue_bytes,
    :sasl_workers,
    :service_workers,
    :snapshot_delta_queue_bytes,
    :snapshot_staging_bytes
  ]

  @timeout_keys [
    :heartbeat_ms,
    :heartbeat_timeout_ms,
    :incomplete_frame_ms,
    :request_ms,
    :shutdown_ms,
    :snapshot_ms,
    :tls_hello_ms
  ]

  defp parse_budget_overrides(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&parse_budget_override/1)
  end

  defp parse_budget_override(pair) do
    case String.split(pair, "=", parts: 2) do
      [name, raw_value] ->
        key = Enum.find(@budget_keys, &(Atom.to_string(&1) == name))

        case {key, Integer.parse(raw_value)} do
          {key, {parsed, ""}} when not is_nil(key) -> {key, parsed}
          _ -> invalid_budget_override!(pair)
        end

      _ ->
        invalid_budget_override!(pair)
    end
  end

  defp invalid_budget_override!(pair),
    do: raise(ArgumentError, "invalid native S2S budget override #{inspect(pair)}")

  defp parse_timeout_overrides(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&parse_timeout_override/1)
  end

  defp parse_timeout_override(pair) do
    case String.split(pair, "=", parts: 2) do
      [name, raw_value] ->
        key = Enum.find(@timeout_keys, &(Atom.to_string(&1) == name))

        case {key, Integer.parse(raw_value)} do
          {key, {parsed, ""}} when not is_nil(key) -> {key, parsed}
          _ -> invalid_timeout_override!(pair)
        end

      _ ->
        invalid_timeout_override!(pair)
    end
  end

  defp invalid_timeout_override!(pair),
    do: raise(ArgumentError, "invalid native S2S timeout override #{inspect(pair)}")
end

ElixIRCd.TestSupport.NativeS2SDaemon.main(System.argv())
