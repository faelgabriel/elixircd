defmodule ElixIRCd.Config.ResourcesTest do
  @moduledoc false
  use ExUnit.Case, async: false
  use Mimic

  alias ElixIRCd.Config.Error
  alias ElixIRCd.Config.Loader
  alias ElixIRCd.Config.Resources
  alias ElixIRCd.Utils.Certificate

  require Record

  Record.defrecordp(
    :cert,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :ec_key,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    config = Loader.read!("config/elixircd.exs")
    keyfile = Path.join(dir, "key.pem")
    certfile = Path.join(dir, "cert.pem")

    config =
      config
      |> put_in([:cloaking, :cloak_key_file], Path.join(dir, "cloak.key"))
      |> Keyword.put(:listeners, tls: [port: 6697, transport_options: [keyfile: keyfile, certfile: certfile]])

    %{config: config, keyfile: keyfile, certfile: certfile}
  end

  for {period, from, until} <- [
        {"expired", {:utcTime, ~c"200101000000Z"}, {:utcTime, ~c"210101000000Z"}},
        {"not yet valid", {:generalTime, ~c"20900101000000Z"}, {:generalTime, ~c"20910101000000Z"}}
      ] do
    test "rejects a matching but #{period} certificate", %{config: config, keyfile: keyfile, certfile: certfile} do
      {der, key} = Certificate.certificate_and_key(2048, "Test", ["localhost"], 365)
      decoded = :public_key.pkix_decode_cert(der, :otp)
      modified = tbs(cert(decoded, :tbsCertificate), validity: {:Validity, unquote(from), unquote(until)})
      File.write!(keyfile, :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)]))

      File.write!(
        certfile,
        :public_key.pem_encode([{:Certificate, :public_key.pkix_sign(modified, key), :not_encrypted}])
      )

      assert_raise Error, ~r/expired or not yet valid/, fn -> Resources.prepare!(config) end
    end
  end

  test "accepts matching EC certificates as well as RSA certificates", %{
    config: config,
    keyfile: keyfile,
    certfile: certfile
  } do
    {der, _rsa_key} = Certificate.certificate_and_key(2048, "Test", ["localhost"], 365)
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    decoded = :public_key.pkix_decode_cert(der, :otp)

    info =
      {:OTPSubjectPublicKeyInfo,
       {:PublicKeyAlgorithm, {1, 2, 840, 10_045, 2, 1}, {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}},
       {:ECPoint, ec_key(key, :publicKey)}}

    modified =
      tbs(cert(decoded, :tbsCertificate),
        signature: {:SignatureAlgorithm, {1, 2, 840, 10_045, 4, 3, 2}, :asn1_NOVALUE},
        subjectPublicKeyInfo: info
      )

    File.write!(keyfile, :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)]))

    File.write!(
      certfile,
      :public_key.pem_encode([{:Certificate, :public_key.pkix_sign(modified, key), :not_encrypted}])
    )

    assert %{files: [{_cloak_path, _key}]} = Resources.prepare!(config)
  end

  test "reports filesystem access errors while inspecting a resource", %{config: config} do
    path = config[:cloaking][:cloak_key_file]
    expect(File, :stat, fn ^path -> {:error, :eacces} end)
    assert_raise File.Error, ~r/permission denied/, fn -> Resources.prepare!(config) end
  end

  test "validates every CA file even when listeners share a certificate", %{config: config, tmp_dir: dir} do
    opts = config[:listeners][:tls]
    ca = Path.join(dir, "ca.pem")
    second = put_in(opts, [:transport_options, :cacertfile], ca) |> Keyword.put(:port, 7000)
    config = Keyword.put(config, :listeners, [{:tls, opts}, {:tls, second}])
    assert_raise Error, ~r/file is missing/, fn -> Resources.prepare!(config) end
    File.write!(ca, "not a certificate")
    assert_raise Error, ~r/expected PEM CA/, fn -> Resources.prepare!(config) end
    refute File.exists?(config[:cloaking][:cloak_key_file])
  end

  test "cleans up the current and earlier files when a write fails", %{tmp_dir: dir} do
    first = Path.join(dir, "first")
    second = Path.join(dir, "second")
    expect(File, :chmod!, fn ^first, 0o600 -> :ok end)
    expect(File, :chmod!, fn ^second, 0o600 -> raise File.Error, reason: :eacces, action: "chmod", path: second end)
    assert_raise File.Error, fn -> Resources.write!([{first, "one"}, {second, "two"}]) end
    refute File.exists?(first)
    refute File.exists?(second)
  end

  test "private material is not generated when no TLS listener uses it", %{config: config} do
    config = Keyword.put(config, :listeners, tcp: [port: 6667])
    prepared = Resources.prepare!(config)
    assert [{path, _key}] = prepared.files
    assert path == config[:cloaking][:cloak_key_file]
  end
end
