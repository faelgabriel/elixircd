defmodule ElixIRCd.Config.ValidatorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.Config.Loader
  alias ElixIRCd.Config.Schema
  alias ElixIRCd.Config.Validator

  setup do
    %{config: Loader.read!("config/elixircd.exs")}
  end

  test "the shipped file satisfies the whole schema", %{config: config} do
    assert :ok = Validator.validate(config)
    assert Enum.sort(Keyword.keys(config)) == Enum.sort(Keyword.keys(Schema.fields()))
  end

  test "every field in the shipped configuration is required, including nullable fields", %{config: config} do
    for path <- keyword_paths(config) do
      invalid = delete_field(config, path)
      assert {:error, errors} = Validator.validate(invalid), "accepted missing #{inspect(path)}"
      assert Enum.any?(errors, &String.contains?(&1, "required field is missing"))
    end
  end

  test "malformed section values produce diagnostics rather than crashes", %{config: config} do
    for {key, _} <- config, malformed <- [nil, true, 12, "secret-value", %{bad: :data}, [1 | 2]] do
      assert {:error, errors} = Validator.validate(Keyword.put(config, key, malformed))
      refute Enum.any?(errors, &String.contains?(&1, "secret-value"))
    end
  end

  test "every configured field rejects an executable function as its value", %{config: config} do
    for path <- keyword_paths(config) do
      assert {:error, _} = Validator.validate(put_in(config, path, fn -> :not_a_value end)), inspect(path)
    end
  end

  test "supports disabling STS and rejects unknown command names and malformed map keys", %{config: config} do
    no_tls = config |> put_in([:capabilities, :sts], false) |> Keyword.put(:listeners, tcp: [port: 6667])
    assert :ok = Validator.validate(no_tls)

    assert {:error, _} =
             Validator.validate(
               put_in(config, [:rate_limiter, :message, :command_throttle], %{
                 "JOIM" => config[:rate_limiter][:message][:throttle]
               })
             )

    assert {:error, errors} = Validator.validate(put_in(config, [:channel, :max_list_entries], %{123 => 100}))
    assert Enum.any?(errors, &String.contains?(&1, "<invalid-key>"))
  end

  test "all declared mail adapters accept a complete configuration", %{config: config} do
    http = [recv_timeout: 30_000, connect_timeout: 5_000]

    variants = [
      [adapter: Bamboo.LocalAdapter],
      [adapter: Bamboo.TestAdapter],
      [adapter: Bamboo.SendGridAdapter, api_key: "test-key", hackney_opts: http],
      [adapter: Bamboo.MandrillAdapter, api_key: "test-key", hackney_opts: http],
      [
        adapter: Bamboo.MailgunAdapter,
        api_key: "test-key",
        domain: "example.com",
        base_uri: "https://api.mailgun.net/v3",
        hackney_opts: http
      ],
      [
        adapter: Bamboo.Mua,
        relay: "smtp.example.com",
        port: 465,
        protocol: :ssl,
        timeout: 30_000,
        mx: false,
        auth: [username: "user", password: "secret"],
        ssl: [verify: :verify_peer],
        tcp: [nodelay: true]
      ]
    ]

    for mailer <- variants do
      assert :ok = Validator.validate(Keyword.put(config, ElixIRCd.Utils.Mailer, mailer))
      assert is_map(mailer[:adapter].handle_config(Map.new(mailer)))
    end
  end

  test "invalid URLs, UTF-8, malformed regular expressions and resource collisions fail", %{config: config} do
    for url <- [
          "https://example.com:65536",
          "https://example.com:bad",
          "ftp://example.com",
          "https://user:secret@example.com"
        ] do
      assert {:error, _} =
               Validator.validate(
                 Keyword.put(config, ElixIRCd.Utils.Mailer,
                   adapter: Bamboo.LocalAdapter,
                   open_email_in_browser_url: url
                 )
               )
    end

    assert {:error, _} = Validator.validate(put_in(config, [:rate_limiter, :connection, :exceptions, :ips], [<<255>>]))

    assert {:error, _} =
             Validator.validate(put_in(config, [:services, :chanserv, :forbidden_channel_names], [%Regex{}]))

    assert {:error, _} =
             Validator.validate(
               put_in(config, [:cloaking, :cloak_key_file], config[:listeners][:tls][:transport_options][:keyfile])
             )
  end

  test "unknown and duplicate fields are rejected together", %{config: config} do
    invalid = config |> Keyword.put(:servre, []) |> Keyword.update!(:user, &[{:max_nick_length, 10} | &1])
    assert {:error, errors} = Validator.validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "servre: unknown field"))
    assert Enum.any?(errors, &String.contains?(&1, "max_nick_length: duplicate field"))
  end

  test "unknown and missing fields are rejected in every configurable branch", %{config: config} do
    command_throttle = config[:rate_limiter][:message][:throttle]

    cases = [
      Keyword.update!(config, ElixIRCd.Utils.Mailer, &Keyword.put(&1, :not_declared, true)),
      put_in(config, [:listeners, :tcp, :not_declared], true),
      put_in(config, [:channel, :max_list_entries], %{b: 100, e: 100, I: 100, not_declared: 100}),
      put_in(config, [:webirc, :gateways], [
        %{ips: ["192.0.2.1"], password: "secret", name: "Gateway", not_declared: true}
      ]),
      put_in(config, [:rate_limiter, :message, :command_throttle], %{
        "JOIN" => Keyword.put(command_throttle, :not_declared, 1)
      }),
      Keyword.update!(config, ElixIRCd.Utils.Mailer, &Keyword.delete(&1, :adapter)),
      put_in(
        config,
        [:listeners, :tls, :transport_options],
        Keyword.delete(config[:listeners][:tls][:transport_options], :keyfile)
      ),
      put_in(config, [:channel, :max_list_entries], %{b: 100, e: 100}),
      put_in(config, [:webirc, :gateways], [%{ips: ["192.0.2.1"], password: "secret"}]),
      put_in(config, [:rate_limiter, :message, :command_throttle], %{
        "JOIN" => Keyword.delete(command_throttle, :cost)
      })
    ]

    for invalid <- cases do
      assert {:error, errors} = Validator.validate(invalid)
      assert match?([_ | _], errors)
    end
  end

  test "required fields inside every shipped listener variant cannot be omitted", %{config: config} do
    paths = [
      [:listeners, :tcp, :port],
      [:listeners, :tls, :port],
      [:listeners, :tls, :transport_options, :keyfile],
      [:listeners, :tls, :transport_options, :certfile],
      [:listeners, :http, :port],
      [:listeners, :http, :startup_log],
      [:listeners, :http, :websocket_options, :compress],
      [:listeners, :https, :port],
      [:listeners, :https, :startup_log],
      [:listeners, :https, :websocket_options, :compress],
      [:listeners, :https, :keyfile],
      [:listeners, :https, :certfile]
    ]

    for path <- paths do
      assert {:error, errors} = Validator.validate(delete_field(config, path)), inspect(path)
      assert Enum.any?(errors, &String.contains?(&1, "required field is missing")), inspect(path)
    end
  end

  for {path, values} <- [
        {[:settings, :case_mapping], [:unicode, "ascii", nil]},
        {[:settings, :utf8_only], ["false", 0, nil]},
        {[:server, :hostname], ["bad host", "host\nINJECT", "-invalid.test", String.duplicate("a", 64)]},
        {[:admin_info, :email], ["invalid", "a@b", "a\nb@c.test"]},
        {[:user, :max_nick_length], [0, -1, 1.5, "30"]},
        {[:ident_service, :timeout], [0, 5_001, :infinity]},
        {[:rate_limiter, :connection, :exceptions, :ips], [["999.0.0.1"], ["localhost"]]},
        {[:rate_limiter, :connection, :exceptions, :cidrs], [["::1/129"], ["127.0.0.1/33"], ["10.0.0.0/-1"]]},
        {[:rate_limiter, :message, :exceptions, :umodes], [["o"], [:q]]},
        {[:services, :chanserv, :settings, :mlock], ["", true]},
        {[:listeners, :tls, :transport_options, :versions], [[:"tlsv1.1"], ["tlsv1.3"]]}
      ] do
    test "rejects unsupported values at #{inspect(path)}", %{config: config} do
      for value <- unquote(Macro.escape(values)) do
        assert {:error, _} = Validator.validate(put_in(config, unquote(path), value))
      end
    end
  end

  test "valid complete command throttles, gateway maps and nullable settings", %{config: config} do
    config =
      config
      |> put_in([:rate_limiter, :message, :command_throttle], %{"JOIN" => config[:rate_limiter][:message][:throttle]})
      |> put_in([:webirc, :gateways], [%{ips: ["192.0.2.1", "2001:db8::/32"], password: "secret", name: "Gateway"}])
      |> put_in([:services, :chanserv, :settings, :keeptopic], false)

    assert :ok = Validator.validate(config)

    assert {:error, _} =
             Validator.validate(put_in(config, [:rate_limiter, :message, :command_throttle], %{"JOIN" => [cost: 2]}))

    assert {:error, _} =
             Validator.validate(put_in(config, [:webirc, :gateways], [%{ips: ["10.0.0.1"], password: "secret"}]))
  end

  test "validates relationships and complete mode limits", %{config: config} do
    invalid =
      config
      |> put_in([:rate_limiter, :message, :throttle, :cost], 999)
      |> put_in([:channel, :channel_join_limits], %{"#" => 20})
      |> put_in([:sts, :port], 1234)

    assert {:error, errors} = Validator.validate(invalid)
    assert length(errors) == 3
    assert {:error, _} = Validator.validate(put_in(config, [:channel, :max_list_entries], %{"b" => 100}))
  end

  test "listener transport, nested options, adapter and credential types are strict", %{config: config} do
    for listener <- [
          {"tcp", []},
          {:udp, []},
          {:tcp, [port: 0]},
          {:tcp, [port: 6667, mystery: true]},
          {:tls, [port: 6697]},
          {:https, [port: 8443]}
        ] do
      assert {:error, _} = Validator.validate(Keyword.put(config, :listeners, [listener]))
    end

    for mailer <- [
          [adapter: "Bamboo.LocalAdapter"],
          [adapter: DoesNotExist],
          [adapter: Bamboo.Mua],
          [adapter: Bamboo.LocalAdapter, password: "secret"]
        ] do
      assert {:error, _} = Validator.validate(Keyword.put(config, ElixIRCd.Utils.Mailer, mailer))
    end

    for operators <- [[{"root", "plain-secret"}], [{"root", "$argon2id$broken"}], [%{name: "root"}]] do
      assert {:error, errors} = Validator.validate(Keyword.put(config, :operators, operators))
      refute Enum.any?(errors, &String.contains?(&1, "plain-secret"))
    end
  end

  defp delete_field(config, [key]), do: Keyword.delete(config, key)
  defp delete_field(config, [key | rest]), do: Keyword.update!(config, key, &delete_field(&1, rest))

  defp keyword_paths(config, prefix \\ []) do
    Enum.flat_map(Keyword.delete(config, :listeners), fn {key, value} ->
      path = prefix ++ [key]
      nested = if Keyword.keyword?(value) and value != [], do: keyword_paths(value, path), else: []
      [path | nested]
    end)
  end
end
