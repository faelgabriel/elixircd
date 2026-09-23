defmodule ElixIRCd.NativeS2SNetworkBench do
  alias ElixIRCd.Server.S2S.TLS

  @cwd File.cwd!()
  @daemon_script Path.join(@cwd, "test/support/native_s2s_daemon.exs")

  def main do
    Application.ensure_all_started(:crypto)
    Application.ensure_all_started(:public_key)
    Application.ensure_all_started(:ssl)

    count = benchmark_count(System.argv())
    tls = create_test_certificates()
    root = start_daemon("root", tls)

    try do
      leaf = start_daemon("leaf", tls, root.port_number)

      try do
        root = await_reachable(root, ~r/reachable_sids: \["leaf", "root"\]/)
        leaf = await_reachable(leaf, ~r/reachable_sids: \["leaf", "root"\]/)
        {:ok, source_line, root} = command(root, "add_client BenchSource\n", "CLIENT ")
        {:ok, target_line, leaf} = command(leaf, "add_client BenchTarget\n", "CLIENT ")
        source_uid = client_uid(source_line)
        target_uid = client_uid(target_line)
        root = await_users(root, 2)
        leaf = await_users(leaf, 2)

        sent_at = System.monotonic_time(:millisecond)
        {samples, root} = send_messages(root, source_uid, target_uid, count)
        leaf = await_message(leaf, "bench-#{count - 1}")
        delivery_ms = System.monotonic_time(:millisecond) - sent_at
        {:ok, root_metrics, root} = command(root, "metrics\n", "METRICS ")
        {:ok, leaf_metrics, _leaf} = command(leaf, "metrics\n", "METRICS ")

        IO.puts(
          "BENCHMARK " <>
            inspect(
              %{
                messages: count,
                send_p50_us: percentile(samples, 0.50),
                send_p95_us: percentile(samples, 0.95),
                send_max_us: Enum.max(samples),
                delivery_ms: delivery_ms,
                schedulers_online: :erlang.system_info(:schedulers_online),
                root_metrics: root_metrics,
                leaf_metrics: leaf_metrics
              },
              limit: :infinity
            )
        )

        _ = root
      after
        stop_daemon(leaf)
      end
    after
      stop_daemon(root)
      File.rm_rf!(tls.dir)
    end
  end

  defp benchmark_count([value | _]) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> raise ArgumentError, "benchmark count must be a positive integer"
    end
  end

  defp benchmark_count(_argv), do: 200

  defp send_messages(daemon, source_uid, target_uid, count) do
    Enum.map_reduce(1..count, daemon, fn index, current ->
      {elapsed_us, result} =
        :timer.tc(fn -> command(current, "send_user #{source_uid} #{target_uid} bench-#{index - 1}\n", "SENT ") end)

      case result do
        {:ok, _line, next} -> {elapsed_us, next}
        {:error, reason} -> raise "message benchmark command failed: #{inspect(reason)}"
      end
    end)
  end

  defp await_reachable(daemon, regex, attempts \\ 150)

  defp await_reachable(_daemon, _regex, 0), do: raise("daemon did not become reachable")

  defp await_reachable(daemon, regex, attempts) do
    case status_line(daemon) do
      {:ok, line, next} when is_binary(line) ->
        if Regex.match?(regex, line), do: next, else: retry(fn -> await_reachable(next, regex, attempts - 1) end)

      {:error, reason} ->
        raise "daemon did not converge: #{inspect(reason)}"
    end
  end

  defp await_users(daemon, expected, attempts \\ 150)

  defp await_users(_daemon, _expected, 0), do: raise("daemon user projection did not converge")

  defp await_users(daemon, expected, attempts) do
    case status_line(daemon) do
      {:ok, line, next} ->
        if Regex.match?(~r/users: #{expected}/, line),
          do: next,
          else: retry(fn -> await_users(next, expected, attempts - 1) end)

      {:error, reason} ->
        raise "daemon user projection failed: #{inspect(reason)}"
    end
  end

  defp await_message(daemon, needle, attempts \\ 150)

  defp await_message(_daemon, _needle, 0), do: raise("daemon message delivery did not converge")

  defp await_message(daemon, needle, attempts) do
    case command(daemon, "read_message\n", "MESSAGE ") do
      {:ok, line, next} ->
        if String.contains?(line, needle), do: next, else: retry(fn -> await_message(next, needle, attempts - 1) end)

      {:error, reason} ->
        raise "daemon message delivery failed: #{inspect(reason)}"
    end
  end

  defp retry(fun) do
    Process.sleep(100)
    fun.()
  end

  defp percentile(samples, fraction) do
    sorted = Enum.sort(samples)
    index = ceil(length(sorted) * fraction) |> max(1) |> min(length(sorted))
    Enum.at(sorted, index - 1)
  end

  defp client_uid("CLIENT " <> uid), do: String.trim(uid)

  defp start_daemon(sid, tls, parent_port \\ nil) do
    mnesia_dir = Path.join(System.tmp_dir!(), "elixircd-native-s2s-bench-#{sid}-#{System.unique_integer([:positive])}")
    File.rm_rf!(mnesia_dir)

    args =
      [
        "run",
        "--no-start",
        @daemon_script,
        "--",
        "--sid",
        sid,
        "--port",
        "0",
        "--mnesia-dir",
        mnesia_dir,
        "--certfp",
        tls.certfp,
        "--certfile",
        tls.certfile,
        "--keyfile",
        tls.keyfile,
        "--cacertfile",
        tls.cacertfile,
        "--peer-certfps",
        "",
        "--topology",
        "two"
      ] ++ if(is_integer(parent_port), do: ["--parent-port", Integer.to_string(parent_port)], else: [])

    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [:binary, :exit_status, {:args, args}, {:cd, @cwd}]
      )

    daemon = %{port: port, mnesia_dir: mnesia_dir, buffer: "", sid: sid}

    case read_line(daemon, "READY ", 15_000) do
      {:ok, line, next} ->
        [_ready, ^sid, port_number] = String.split(line, " ", parts: 3)
        Map.put(next, :port_number, String.to_integer(port_number))

      {:error, reason} ->
        if Port.info(port) != nil, do: Port.close(port)
        raise "native S2S benchmark daemon #{sid} did not start: #{inspect(reason)}"
    end
  end

  defp stop_daemon(%{port: port, mnesia_dir: dir} = daemon) do
    if Port.info(port) != nil do
      _ = command(daemon, "stop\n", "STOPPED")
      _ = wait_for_exit(port, 5_000)
    end

    File.rm_rf!(dir)
  end

  defp status_line(daemon), do: command(daemon, "status\n", "STATUS ")

  defp command(daemon, input, prefix) do
    Port.command(daemon.port, input)
    read_line(daemon, prefix, 10_000)
  rescue
    error -> {:error, {:port_command, error}}
  end

  defp read_line(daemon, prefix, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_line_until(daemon, prefix, deadline)
  end

  defp read_line_until(%{buffer: buffer} = daemon, prefix, deadline) do
    case :binary.match(buffer, "\n") do
      {index, 1} ->
        line = binary_part(buffer, 0, index) |> String.trim_trailing("\r")
        rest = binary_part(buffer, index + 1, byte_size(buffer) - index - 1)

        if String.starts_with?(line, prefix),
          do: {:ok, line, %{daemon | buffer: rest}},
          else: read_line_until(%{daemon | buffer: rest}, prefix, deadline)

      :nomatch ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {port, {:data, data}} when port == daemon.port ->
            read_line_until(%{daemon | buffer: buffer <> data}, prefix, deadline)

          {port, {:exit_status, status}} when port == daemon.port ->
            {:error, {:exit_status, status, buffer}}
        after
          remaining -> {:error, :timeout}
        end
    end
  end

  defp wait_for_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> status
    after
      timeout_ms -> :timeout
    end
  end

  defp create_test_certificates do
    dir = Path.join(System.tmp_dir!(), "elixircd-native-s2s-bench-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ca_config = Path.join(dir, "ca.cnf")
    node_config = Path.join(dir, "node.cnf")
    ca_key = Path.join(dir, "ca.key")
    cacertfile = Path.join(dir, "ca.pem")
    node_key = Path.join(dir, "node.key")
    node_csr = Path.join(dir, "node.csr")
    certfile = Path.join(dir, "node.pem")
    ca_serial = Path.join(dir, "ca.srl")

    File.write!(ca_config, """
    [req]
    distinguished_name = req_dn
    x509_extensions = v3_ca
    prompt = no

    [req_dn]
    CN = ElixIRCd Native S2S Benchmark CA

    [v3_ca]
    basicConstraints = critical,CA:TRUE
    keyUsage = critical,keyCertSign,cRLSign
    subjectKeyIdentifier = hash
    """)

    File.write!(node_config, """
    [req]
    distinguished_name = req_dn
    prompt = no

    [req_dn]
    CN = localhost

    [v3_node]
    basicConstraints = critical,CA:FALSE
    keyUsage = critical,digitalSignature,keyEncipherment
    extendedKeyUsage = serverAuth,clientAuth
    subjectAltName = DNS:localhost
    subjectKeyIdentifier = hash
    """)

    run_openssl!("req", [
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      ca_key,
      "-out",
      cacertfile,
      "-days",
      "365",
      "-sha256",
      "-config",
      ca_config
    ])

    run_openssl!("req", ["-newkey", "rsa:2048", "-nodes", "-keyout", node_key, "-out", node_csr, "-config", node_config])

    run_openssl!("x509", [
      "-req",
      "-in",
      node_csr,
      "-CA",
      cacertfile,
      "-CAkey",
      ca_key,
      "-CAserial",
      ca_serial,
      "-CAcreateserial",
      "-out",
      certfile,
      "-days",
      "365",
      "-sha256",
      "-extfile",
      node_config,
      "-extensions",
      "v3_node"
    ])

    {:ok, pem} = File.read(certfile)

    der =
      pem
      |> :public_key.pem_decode()
      |> Enum.find_value(fn
        {:Certificate, certificate, _} -> certificate
        _ -> nil
      end)

    %{dir: dir, certfile: certfile, keyfile: node_key, cacertfile: cacertfile, certfp: TLS.fingerprint(der)}
  end

  defp run_openssl!(subcommand, args) do
    case System.cmd("openssl", [subcommand | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "openssl #{subcommand} failed with #{status}: #{output}"
    end
  end
end

ElixIRCd.NativeS2SNetworkBench.main()
