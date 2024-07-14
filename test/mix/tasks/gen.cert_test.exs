
# It includes code from the Phoenix Framework, which is licensed under the MIT License.
# The original file can be found at:
# https://github.com/phoenixframework/phoenix/blob/main/lib/mix/tasks/phx.gen.cert.ex
#
# This file is included here with minimal modifications for use in ElixIRCd.

# Get Mix output sent to the current
# process to avoid polluting tests.
Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.Gen.CertTest do
  @moduledoc """
  This test file was extracted from the Phoenix Framework source code with minimal modifications:
  https://github.com/phoenixframework/phoenix/blob/main/test/mix/tasks/phx.gen.cert_test.exs
  """

  use ExUnit.Case

  alias Mix.Tasks.Gen

  @timeout 5_000

  test "write certificate and key files" do
    in_tmp("mix_gen_cert", fn ->
      Gen.Cert.run([])

      assert_file("priv/cert/selfsigned_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("priv/cert/selfsigned.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "write certificate and key with custom filename" do
    in_tmp("mix_gen_cert", fn ->
      Gen.Cert.run(["-o", "priv/cert/localhost"])

      assert_file("priv/cert/localhost_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("priv/cert/localhost.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "write certificate and key with custom hostnames" do
    in_tmp("mix_gen_cert", fn ->
      Gen.Cert.run(["my-app", "my-app.local"])

      assert_file("priv/cert/selfsigned_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("priv/cert/selfsigned.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "TLS connection with generated certificate and key" do
    Application.ensure_all_started(:ssl)

    in_tmp("mix_gen_cert", fn ->
      Gen.Cert.run([])

      assert {:ok, server} =
               :ssl.listen(
                 0,
                 certfile: "priv/cert/selfsigned.pem",
                 keyfile: "priv/cert/selfsigned_key.pem"
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

  defp assert_file(file) do
    assert File.regular?(file), "Expected #{file} to exist, but does not"
  end

  defp assert_file(file, match) do
    cond do
      is_list(match) ->
        assert_file(file, &Enum.each(match, fn m -> assert &1 =~ m end))

      is_binary(match) or is_struct(match, Regex) ->
        assert_file(file, &assert(&1 =~ match))

      is_function(match, 1) ->
        assert_file(file)
        match.(File.read!(file))

      true ->
        raise inspect({file, match})
    end
  end

  defp tmp_path do
    Path.expand("../../tmp", __DIR__)
  end

  defp random_string(len) do
    len |> :crypto.strong_rand_bytes() |> Base.url_encode64() |> binary_part(0, len)
  end

  defp in_tmp(which, function) do
    base = Path.join([tmp_path(), random_string(10)])
    path = Path.join([base, to_string(which)])

    try do
      File.rm_rf!(path)
      File.mkdir_p!(path)
      File.cd!(path, function)
    after
      File.rm_rf!(base)
    end
  end
end
