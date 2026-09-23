defmodule ElixIRCd.Config.LoaderTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias ElixIRCd.Config.Error
  alias ElixIRCd.Config.Loader
  alias ElixIRCd.Config.Resources
  alias ElixIRCd.Tables.RegisteredChannel.Settings
  alias ElixIRCd.Utils.Certificate
  alias ElixIRCd.Utils.HostnameCloaking

  setup do
    dir = Path.join(System.tmp_dir!(), "elixircd-loader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old = Application.get_all_env(:elixircd)
    key = :persistent_term.get(HostnameCloaking)

    on_exit(fn ->
      Application.put_all_env(elixircd: old)
      :persistent_term.put(HostnameCloaking, key)
      File.rm_rf!(dir)
    end)

    config = Loader.read!("config/elixircd.exs")
    config = put_in(config, [:cloaking, :cloak_key_file], Path.join(dir, "cloak.key"))
    %{dir: dir, config: config, path: Path.join(dir, "elixircd.exs")}
  end

  test "read errors and expression failures are safe and actionable", %{path: path} do
    assert_raise Error, ~r/no such file/, fn -> Loader.read!(path) end

    for {source, match} <- [
          {"import Config\nconfig :elixircd, server: [", "syntax"},
          {"raise \"TOP-SECRET\"", "evaluation failed"},
          {"throw(:secret)", "evaluation failed"},
          {"exit(:secret)", "evaluation failed"},
          {"import Config\nconfig :logger, level: :info", ":elixircd only"},
          {"import Config\nconfig :elixircd, server: []", "required field"}
        ] do
      File.write!(path, source)
      error = assert_raise Error, fn -> Loader.read!(path) end
      assert Exception.message(error) =~ match
      refute Exception.message(error) =~ "TOP-SECRET"
    end
  end

  test "invalid reload preserves environment and cloak and creates no resources", %{
    config: config,
    dir: dir,
    path: path
  } do
    before = Application.get_all_env(:elixircd)
    key = :persistent_term.get(HostnameCloaking)
    write_config(path, Keyword.delete(config, :user))
    assert_raise Error, fn -> Loader.load!(path, :reload) end
    assert Application.get_all_env(:elixircd) == before
    assert :persistent_term.get(HostnameCloaking) == key
    refute File.exists?(Path.join(dir, "cloak.key"))
  end

  test "load rejects unknown and missing schema fields before preparing resources", %{
    config: config,
    dir: dir,
    path: path
  } do
    cases = [
      {
        Keyword.put(config, :not_declared, true),
        "elixircd.not_declared: unknown field"
      },
      {
        Keyword.update!(config, :server, &Keyword.put(&1, :not_declared, true)),
        "elixircd.server.not_declared: unknown field"
      },
      {
        Keyword.delete(config, :admin_info),
        "elixircd.admin_info: required field is missing"
      },
      {
        Keyword.update!(config, :server, &Keyword.delete(&1, :hostname)),
        "elixircd.server.hostname: required field is missing"
      }
    ]

    for {invalid, detail} <- cases do
      write_config(path, invalid)

      error = assert_raise Error, fn -> Loader.load!(path, :boot) end
      assert Exception.message(error) =~ detail
      refute File.exists?(Path.join(dir, "cloak.key"))
    end
  end

  test "upgrades pre-feature configuration with disabled compatibility defaults", %{config: config, path: path} do
    new_capabilities = [
      :account_registration,
      :chathistory,
      :channel_rename,
      :event_playback,
      :message_redaction,
      :metadata,
      :multiline,
      :read_marker
    ]

    legacy_capabilities = Keyword.drop(config[:capabilities], new_capabilities)

    legacy =
      config
      |> Keyword.drop([
        :compatibility,
        :history,
        :redaction,
        :metadata,
        :read_markers,
        :multiline,
        :account_registration,
        :channel_rename
      ])
      |> Keyword.put(:capabilities, legacy_capabilities)
      |> update_in([:sasl], &Keyword.delete(&1, :scram_sha_256))

    write_config(path, legacy)
    upgraded = Loader.read!(path)

    assert upgraded[:history][:enabled] == false
    assert upgraded[:metadata][:enabled] == false
    assert upgraded[:compatibility][:deprecated_metadata] == false
    assert upgraded[:sasl][:scram_sha_256] == [enabled: false, iterations: 15_000]
    assert Enum.all?(new_capabilities, &(upgraded[:capabilities][&1] == false))
  end

  test "rejects malformed legacy roots and SASL sections after safe upgrade", %{config: config, path: path} do
    for invalid <- [
          123,
          Keyword.put(config, :sasl, :invalid),
          Keyword.put(config, :sasl, ["not-a-keyword"])
        ] do
      File.write!(path, "import Config\nconfig :elixircd, #{inspect(invalid, limit: :infinity)}")
      assert_raise Error, fn -> Loader.read!(path) end
    end
  end

  test "read validation is side effect free and valid reload replaces nested sections", %{
    config: config,
    path: path,
    dir: dir
  } do
    config = put_in(config, [:server, :name], "Changed network")
    write_config(path, config)
    assert :ok = Loader.check!(path)
    assert inspect(Loader.read!(path), limit: :infinity) == inspect(config, limit: :infinity)
    refute File.exists?(Path.join(dir, "cloak.key"))
    Application.put_env(:elixircd, :obsolete_config, true)
    Application.put_env(:elixircd, :server, Application.fetch_env!(:elixircd, :server) ++ [obsolete: true])
    assert :ok = Loader.load!(path, :reload)
    assert Application.fetch_env!(:elixircd, :server) == config[:server]
    assert Application.fetch_env(:elixircd, :obsolete_config) == :error
    assert File.read!(Path.join(dir, "cloak.key")) == :persistent_term.get(HostnameCloaking)
    assert Bitwise.band(File.stat!(Path.join(dir, "cloak.key")).mode, 0o777) == 0o600
    assert :ok = Loader.load!(path, :reload)
  end

  test "restart-only changes are rejected before writes", %{config: config, path: path, dir: dir} do
    for invalid <- [
          put_in(config, [:settings, :case_mapping], :ascii),
          put_in(config, [:server, :hostname], "other.test"),
          Keyword.update!(config, :listeners, &Enum.reverse/1)
        ] do
      write_config(path, invalid)
      assert_raise Error, ~r/requires server restart/, fn -> Loader.load!(path, :reload) end
      refute File.exists?(Path.join(dir, "cloak.key"))
    end
  end

  test "generates local certificate pair once, validates it again and performs TLS handshake", %{
    config: config,
    dir: dir
  } do
    File.cd!(dir, fn ->
      config = local_tls(config, dir)
      prepared = Resources.prepare!(config)
      assert length(prepared.files) == 3
      assert :ok = Resources.write!(prepared.files)
      assert Resources.prepare!(config).files == []
      tls = config[:listeners][:tls][:transport_options]
      assert Bitwise.band(File.stat!(tls[:keyfile]).mode, 0o777) == 0o600
      {:ok, socket} = :ssl.listen(0, tls)
      {:ok, {_, port}} = :ssl.sockname(socket)

      task =
        Task.async(fn ->
          {:ok, conn} = :ssl.transport_accept(socket, 5_000)
          {:ok, conn} = :ssl.handshake(conn, 5_000)
          :ssl.close(conn)
        end)

      assert {:ok, client} = :ssl.connect(~c"localhost", port, [verify: :verify_none], 5_000)
      :ssl.close(client)
      Task.await(task)
      :ssl.close(socket)
    end)
  end

  test "HTTPS alone generates the local pair from relative listener paths", %{config: config, dir: dir} do
    File.cd!(dir, fn ->
      config =
        config
        |> put_in([:capabilities, :sts], false)
        |> Keyword.put(:listeners,
          https: [
            port: 8443,
            startup_log: false,
            websocket_options: [compress: false],
            keyfile: "data/cert/selfsigned_key.pem",
            certfile: "data/cert/selfsigned.pem"
          ]
        )

      write_config("elixircd.exs", config)
      assert :ok = Loader.check!("elixircd.exs")
      refute File.exists?("data")
      assert :ok = Loader.load!("elixircd.exs", :boot)
      assert File.regular?("data/cert/selfsigned_key.pem")
      assert File.regular?("data/cert/selfsigned.pem")
      assert Resources.prepare!(config).files == []
    end)
  end

  test "refuses corrupt, missing and mismatched TLS material without activating cloak", %{
    config: config,
    dir: dir,
    path: path
  } do
    File.cd!(dir, fn ->
      config = local_tls(config, dir)
      config |> Resources.prepare!() |> Map.fetch!(:files) |> Resources.write!()
      keyfile = config[:listeners][:tls][:transport_options][:keyfile]
      certfile = config[:listeners][:tls][:transport_options][:certfile]
      original_key = File.read!(keyfile)
      original_cert = File.read!(certfile)
      old_key = :persistent_term.get(HostnameCloaking)
      write_config(path, config)
      File.write!(certfile, "invalid PEM")
      assert_raise Error, ~r/invalid PEM/, fn -> Loader.load!(path, :boot) end
      assert :persistent_term.get(HostnameCloaking) == old_key
      File.write!(certfile, original_cert)
      {_cert, other_key} = Certificate.certificate_and_key(2048, "Other", ["localhost"], 365)
      File.write!(keyfile, :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, other_key)]))
      assert_raise Error, ~r/mismatched/, fn -> Resources.prepare!(config) end
      File.write!(keyfile, original_key)
      File.rm!(certfile)
      assert_raise Error, ~r/certificate is missing/, fn -> Resources.prepare!(config) end
      assert File.read!(keyfile) == original_key
    end)
  end

  test "invalid cloak files and failed writes preserve existing files", %{config: config, dir: dir} do
    cloak = config[:cloaking][:cloak_key_file]
    File.write!(cloak, "short")
    assert_raise Error, ~r/at least 32 bytes/, fn -> Resources.prepare!(config) end
    first = Path.join(dir, "first")
    assert_raise File.Error, fn -> Resources.write!([{first, "new"}, {cloak, "overwrite"}]) end
    refute File.exists?(first)
    assert File.read!(cloak) == "short"
  end

  test "externally supplied certificates must exist", %{config: config, dir: dir} do
    config = local_tls(config, dir)
    assert_raise Error, ~r/private key is missing/, fn -> Resources.prepare!(config) end
    assert File.ls!(dir) == []
  end

  test "configured false channel settings remain false after creation", %{config: config, path: path} do
    flags = [:keeptopic, :opnotice, :fantasy, :guard]

    config =
      Enum.reduce(flags, config, fn flag, config -> put_in(config, [:services, :chanserv, :settings, flag], false) end)

    write_config(path, config)
    Loader.load!(path, :reload)
    settings = Settings.new()
    for flag <- flags, do: assert(Map.fetch!(settings, flag) == false)
  end

  defp write_config(path, config) do
    File.write!(
      path,
      "import Config\nconfig :elixircd, " <> inspect(config, limit: :infinity, printable_limit: :infinity)
    )
  end

  defp local_tls(config, dir) do
    keyfile = Path.join(dir, "data/cert/selfsigned_key.pem")
    certfile = Path.join(dir, "data/cert/selfsigned.pem")

    Keyword.put(config, :listeners, tls: [port: 6697, transport_options: [keyfile: keyfile, certfile: certfile]])
  end
end
