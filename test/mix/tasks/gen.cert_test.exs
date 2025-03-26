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

  import ElixIRCd.TestHelpers, only: [assert_file: 2, in_tmp: 2]

  alias Mix.Tasks.Gen

  @timeout 5_000

  test "write certificate and key files" do
    in_tmp("mix_gen_cert", fn ->
      Gen.Cert.run([])

      assert_file("data/cert/selfsigned_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("data/cert/selfsigned.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "write certificate and key with custom filename" do
    in_tmp("mix_gen_cert", fn ->
      Gen.Cert.run(["-o", "data/cert/localhost"])

      assert_file("data/cert/localhost_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("data/cert/localhost.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "write certificate and key with custom hostnames" do
    in_tmp("mix_gen_cert", fn ->
      Gen.Cert.run(["my-app", "my-app.local"])

      assert_file("data/cert/selfsigned_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
      assert_file("data/cert/selfsigned.pem", "-----BEGIN CERTIFICATE-----")
    end)
  end

  test "TLS connection with generated certificate and key" do
    Application.ensure_all_started(:ssl)

    in_tmp("mix_gen_cert", fn ->
      Gen.Cert.run([])

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
end
