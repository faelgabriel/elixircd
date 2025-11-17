defmodule ElixIRCd.Utils.Certificate do
  # It includes code from the Phoenix Framework, which is licensed under the MIT License.
  # The original file can be found at:
  # https://github.com/phoenixframework/phoenix/blob/main/lib/mix/tasks/phx.gen.cert.ex
  #
  # This file is included here with minimal modifications for use in ElixIRCd.

  @moduledoc """
  Utility for generating a self-signed certificate for SSL testing.

  WARNING: only use the generated certificate for testing in a closed network
  environment, such as running a development server on `localhost`.
  For production, staging, or testing servers on the public internet, obtain a
  proper certificate, for example from [Let's Encrypt](https://letsencrypt.org).
  """

  require Logger

  @default_path "data/cert/selfsigned"
  @default_name "Self-signed test certificate"
  @default_hostnames ["localhost"]

  @doc """
  Generates a self-signed certificate for SSL testing.

  ## Options

    * `:output`: the path and base filename for the certificate and
      key (default: #{@default_path})
    * `:name`: the Common Name value in certificate's subject
      (default: "#{@default_name}")
    * `:hostnames`: a list of hostnames for the certificate (default: ["localhost"])

  Requires OTP 21.3 or later.
  """
  @spec create_self_signed_certificate(keyword()) :: :ok
  def create_self_signed_certificate(opts \\ []) do
    path = opts[:output] || @default_path
    name = opts[:name] || @default_name
    hostnames = opts[:hostnames] || @default_hostnames

    {certificate, private_key} = certificate_and_key(2048, name, hostnames)

    keyfile = path <> "_key.pem"
    certfile = path <> ".pem"

    create_file(
      keyfile,
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    )

    create_file(
      certfile,
      :public_key.pem_encode([{:Certificate, certificate, :not_encrypted}])
    )

    :ok
  end

  @doc """
  Generates a certificate and private key pair.

  Creates an RSA key pair with the specified key size and generates a self-signed
  certificate with the given common name and hostnames.

  ## Parameters

    * `key_size` - The size of the RSA key in bits
    * `name` - The common name to use in the certificate
    * `hostnames` - A list of hostnames to include in the subject alternative name extension

  ## Returns

  A tuple containing the certificate and private key.
  """
  @spec certificate_and_key(integer(), String.t(), [String.t()]) :: {term(), term()}
  def certificate_and_key(key_size, name, hostnames) do
    private_key = :public_key.generate_key({:rsa, key_size, 65_537})
    public_key = extract_public_key(private_key)

    certificate =
      public_key
      |> new_cert(name, hostnames)
      |> :public_key.pkix_sign(private_key)

    {certificate, private_key}
  end

  require Record

  # RSA key pairs

  Record.defrecordp(
    :rsa_private_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :rsa_public_key,
    :RSAPublicKey,
    Record.extract(:RSAPublicKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @spec extract_public_key(term()) :: term()
  defp extract_public_key(rsa_private_key(modulus: m, publicExponent: e)) do
    rsa_public_key(modulus: m, publicExponent: e)
  end

  # Certificates

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :signature_algorithm,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :public_key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :basic_constraints,
    :BasicConstraints,
    Record.extract(:BasicConstraints, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :attr,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  # OID values
  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @sha256_withrsa_encryption {1, 2, 840, 113_549, 1, 1, 11}

  @basic_constraints {2, 5, 29, 19}
  @key_usage {2, 5, 29, 15}
  @extendedkey_usage {2, 5, 29, 37}
  @subject_key_identifier {2, 5, 29, 14}
  @subject_alternative_name {2, 5, 29, 17}

  @organization_name {2, 5, 4, 10}
  @common_name {2, 5, 4, 3}

  @server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @client_auth {1, 3, 6, 1, 5, 5, 7, 3, 2}

  @spec new_cert(term(), String.t(), [String.t()]) :: term()
  defp new_cert(public_key, common_name, hostnames) do
    <<serial::unsigned-64>> = :crypto.strong_rand_bytes(8)

    today = Date.utc_today()

    not_before =
      today
      |> Date.to_iso8601(:basic)
      |> String.slice(2, 6)

    not_after =
      today
      |> Date.add(365)
      |> Date.to_iso8601(:basic)
      |> String.slice(2, 6)

    otp_tbs_certificate(
      version: :v3,
      serialNumber: serial,
      signature: signature_algorithm(algorithm: @sha256_withrsa_encryption),
      issuer: rdn(common_name),
      validity:
        validity(
          notBefore: {:utcTime, ~c"#{not_before}000000Z"},
          notAfter: {:utcTime, ~c"#{not_after}000000Z"}
        ),
      subject: rdn(common_name),
      subjectPublicKeyInfo:
        otp_subject_public_key_info(
          algorithm: public_key_algorithm(algorithm: @rsa_encryption),
          subjectPublicKey: public_key
        ),
      extensions: extensions(public_key, hostnames)
    )
  end

  @spec rdn(String.t()) :: {:rdnSequence, list()}
  defp rdn(common_name) do
    {:rdnSequence,
     [
       [attr(type: @organization_name, value: {:utf8String, "ElixIRCd"})],
       [attr(type: @common_name, value: {:utf8String, common_name})]
     ]}
  end

  @spec extensions(term(), [String.t()]) :: list()
  defp extensions(public_key, hostnames) do
    [
      extension(
        extnID: @basic_constraints,
        critical: true,
        extnValue: basic_constraints(cA: false)
      ),
      extension(
        extnID: @key_usage,
        critical: true,
        extnValue: [:digitalSignature, :keyEncipherment]
      ),
      extension(
        extnID: @extendedkey_usage,
        critical: false,
        extnValue: [@server_auth, @client_auth]
      ),
      extension(
        extnID: @subject_key_identifier,
        critical: false,
        extnValue: key_identifier(public_key)
      ),
      extension(
        extnID: @subject_alternative_name,
        critical: false,
        extnValue: Enum.map(hostnames, &{:dNSName, String.to_charlist(&1)})
      )
    ]
  end

  @spec key_identifier(term()) :: binary()
  defp key_identifier(public_key) do
    :crypto.hash(:sha, :public_key.der_encode(:RSAPublicKey, public_key))
  end

  # sobelow_skip ["Traversal.FileModule"]
  @spec create_file(String.t(), iodata()) :: true
  defp create_file(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    true
  end
end
