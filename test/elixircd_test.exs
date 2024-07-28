defmodule ElixIRCdTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ElixIRCd.TestHelpers, only: [assert_file: 2, in_tmp: 2]

  describe "start/2" do
    test "generates self-signed certificate if it is configured and does not exist yet" do
      in_tmp("self_signed_certificate", fn ->
        :ok = Application.stop(:elixircd)
        :ok = Application.start(:elixircd)

        assert_file("priv/cert/selfsigned_key.pem", "-----BEGIN RSA PRIVATE KEY-----")
        assert_file("priv/cert/selfsigned.pem", "-----BEGIN CERTIFICATE-----")
      end)
    end
  end
end
