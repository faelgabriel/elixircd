defmodule ElixIRCdTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ElixIRCd.TestHelpers, only: [assert_file: 2]
  import WaitForIt

  describe "start/2" do
    test "generates self-signed certificate if it is configured and does not exist yet" do
      :ok = Application.stop(:elixircd)
      File.rm!("priv/cert/selfsigned_key.pem")
      File.rm!("priv/cert/selfsigned.pem")
      :ok = Application.start(:elixircd)

      assert wait(assert_file("priv/cert/selfsigned_key.pem", "-----BEGIN RSA PRIVATE KEY-----"))
      assert wait(assert_file("priv/cert/selfsigned.pem", "-----BEGIN CERTIFICATE-----"))
    end
  end
end
