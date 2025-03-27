defmodule ElixIRCd.Utils.CertificateTest do
  @moduledoc """
  Tests for certificate generation functionality.
  """

  use ExUnit.Case

  alias ElixIRCd.Utils.Certificate

  @timeout 5_000

  test "write certificate and key files" do
    in_tmp("certificate_test", fn ->
      Certificate.create_self_signed_certificate()

      assert_file("data/cert/selfsigned_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("data/cert/selfsigned.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "write certificate and key with custom filename" do
    in_tmp("certificate_test", fn ->
      Certificate.create_self_signed_certificate(output: "data/cert/localhost")

      assert_file("data/cert/localhost_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("data/cert/localhost.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "write certificate and key with custom hostnames" do
    in_tmp("certificate_test", fn ->
      Certificate.create_self_signed_certificate(hostnames: ["my-app", "my-app.local"])

      assert_file("data/cert/selfsigned_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("data/cert/selfsigned.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "TLS connection with generated certificate and key" do
    Application.ensure_all_started(:ssl)

    in_tmp("certificate_test", fn ->
      Certificate.create_self_signed_certificate()

      assert {:ok, server} =
               :ssl.listen(
                 0,
                 certfile: "data/cert/selfsigned.pem",
                 keyfile: "data/cert/selfsigned_key.pem"
               )

      {:ok, {_, port}} = :ssl.sockname(server)

      spawn_link(fn ->
        with {:ok, conn} <- :ssl.transport_accept(server, @timeout),
             :ok <- :ssl.handshake(conn, @timeout) do
          :ssl.close(conn)
        end
      end)

      # We don't actually verify the server cert contents, we just check that
      # the client and server are able to complete the TLS handshake
      assert {:ok, client} = :ssl.connect(~c"localhost", port, [verify: :verify_none], @timeout)
      :ssl.close(client)
      :ssl.close(server)
    end)
  end

  @spec assert_file(binary()) :: true
  defp assert_file(file) do
    assert File.regular?(file), "Expected #{file} to exist, but does not"
  end

  @spec assert_file(binary(), binary() | [binary()] | Regex.t() | (binary() -> any())) :: true
  defp assert_file(file, match) do
    cond do
      is_binary(match) or is_struct(match, Regex) ->
        assert_file(file, &assert(&1 =~ match))

      is_function(match, 1) ->
        assert_file(file)
        match.(File.read!(file))
    end
  end

  @spec in_tmp(binary(), (-> any())) :: any
  defp in_tmp(which, function) do
    tmp_path = Path.expand("../../tmp", __DIR__)
    random_string = :crypto.strong_rand_bytes(10) |> Base.url_encode64() |> binary_part(0, 10)

    base = Path.join([tmp_path, random_string])
    path = Path.join([base, to_string(which)])

    try do
      File.rm_rf!(path)
      File.mkdir_p!(path)
      File.cd!(path, function)
    after
      File.rm_rf!(base)
      File.rm_rf!(tmp_path)
    end
  end
end
