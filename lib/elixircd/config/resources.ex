defmodule ElixIRCd.Config.Resources do
  @moduledoc "Prepares configuration files before activation; never replaces existing keys or certificates."

  alias ElixIRCd.Config.Error
  alias ElixIRCd.Utils.Certificate

  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :public_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :cert_validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @type prepared :: %{cloak_key: binary(), files: [{String.t(), binary()}]}

  @doc "Reads and checks every referenced resource, generating missing local material in memory."
  @spec prepare!(keyword()) :: prepared()
  def prepare!(config) do
    {key, cloak_files} = prepare_cloak!(config[:cloaking][:cloak_key_file])
    certificate_files = prepare_certificates!(config)
    %{cloak_key: key, files: cloak_files ++ certificate_files}
  end

  @doc "Creates prepared files exclusively and removes this attempt's files if a write fails."
  @spec write!([{String.t(), binary()}]) :: :ok
  def write!(files), do: write_files!(files, [])

  @doc "Reads or creates the cloak secret without activating it. Existing secrets must contain at least 32 bytes."
  @spec cloak_key!(String.t()) :: binary()
  def cloak_key!(path) do
    {key, files} = prepare_cloak!(path)
    write!(files)
    key
  end

  @spec prepare_cloak!(String.t()) :: {binary(), list()}
  defp prepare_cloak!(path) do
    case read_optional!(path) do
      nil ->
        key = Base.encode64(:crypto.strong_rand_bytes(32))
        {key, [{path, key}]}

      key ->
        if byte_size(String.trim(key)) < 32, do: fail!(path, "cloak key must contain at least 32 bytes")
        {key, []}
    end
  end

  @spec prepare_certificates!(keyword()) :: list()
  defp prepare_certificates!(config) do
    pairs =
      Enum.flat_map(config[:listeners], fn
        {:tls, opts} -> [opts[:transport_options]]
        {:https, opts} -> [opts]
        _ -> []
      end)

    pairs = if config[:server_links][:listen], do: [config[:server_links][:listen] | pairs], else: pairs

    Enum.each(pairs, fn opts -> if opts[:cacertfile], do: validate_ca!(opts[:cacertfile]) end)
    mailer = config[ElixIRCd.Utils.Mailer]
    if mailer[:adapter] == Bamboo.Mua and mailer[:ssl][:cacertfile], do: validate_ca!(mailer[:ssl][:cacertfile])

    pairs
    |> Enum.uniq_by(&{Path.expand(&1[:keyfile]), Path.expand(&1[:certfile])})
    |> Enum.flat_map(&prepare_pair!/1)
  end

  @spec prepare_pair!(keyword()) :: list()
  defp prepare_pair!(opts) do
    keyfile = opts[:keyfile]
    certfile = opts[:certfile]
    key_pem = read_optional!(keyfile)
    cert_pem = read_optional!(certfile)

    # The shipped listener paths enable effortless local startup without extra configuration.
    generated? =
      Path.expand(keyfile) == Path.expand("data/cert/selfsigned_key.pem") and
        Path.expand(certfile) == Path.expand("data/cert/selfsigned.pem")

    case {key_pem, cert_pem, generated?} do
      {nil, nil, true} ->
        {cert, key} =
          Certificate.certificate_and_key(2048, "Self-signed test certificate", ["localhost"], 365)

        [
          {keyfile, :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])},
          {certfile, :public_key.pem_encode([{:Certificate, cert, :not_encrypted}])}
        ]

      {nil, _, _} ->
        fail!(keyfile, "private key is missing; local generation requires both configured files to be absent")

      {_, nil, _} ->
        fail!(certfile, "certificate is missing; local generation requires both configured files to be absent")

      {key, cert, _} ->
        validate_pair!(keyfile, key, certfile, cert)
        []
    end
  end

  @spec validate_pair!(String.t(), binary(), String.t(), binary()) :: :ok
  defp validate_pair!(keyfile, key_pem, certfile, cert_pem) do
    [key_entry] = :public_key.pem_decode(key_pem)
    key = :public_key.pem_entry_decode(key_entry)
    [decoded | _] = decode_certificates!(cert_pem)
    validity = decoded |> otp_certificate(:tbsCertificate) |> otp_tbs(:validity)
    now = :calendar.universal_time() |> :calendar.datetime_to_gregorian_seconds()

    not_before = asn1_time(cert_validity(validity, :notBefore))
    not_after = asn1_time(cert_validity(validity, :notAfter))

    unless not_before <= now and now < not_after,
      do: fail!(certfile, "certificate is expired or not yet valid")

    spki = decoded |> otp_certificate(:tbsCertificate) |> otp_tbs(:subjectPublicKeyInfo)
    public = otp_spki(spki, :subjectPublicKey)

    public =
      case public do
        {:ECPoint, _} -> {public, spki |> otp_spki(:algorithm) |> public_algorithm(:parameters)}
        _ -> public
      end

    signature = :public_key.sign("ElixIRCd configuration key check", :sha256, key)
    true = :public_key.verify("ElixIRCd configuration key check", :sha256, signature, public)
    :ok
  rescue
    error in Error -> reraise error, __STACKTRACE__
    _ -> fail!(certfile, "invalid PEM certificate/private key or mismatched key pair (keyfile: #{keyfile})")
  end

  @spec validate_ca!(String.t()) :: :ok
  defp validate_ca!(path) do
    pem = read_required!(path)

    try do
      [_ | _] = decode_certificates!(pem)
      :ok
    rescue
      _ -> fail!(path, "expected PEM CA certificates")
    end
  end

  @spec decode_certificates!(binary()) :: [tuple()]
  defp decode_certificates!(pem) do
    Enum.map(:public_key.pem_decode(pem), fn {:Certificate, der, :not_encrypted} ->
      :public_key.pkix_decode_cert(der, :otp)
    end)
  end

  @spec asn1_time(tuple()) :: integer()
  defp asn1_time({:utcTime, value}) do
    <<year::binary-size(2), rest::binary>> = to_string(value)
    century = if String.to_integer(year) >= 50, do: "19", else: "20"
    asn1_time({:generalTime, century <> year <> rest})
  end

  defp asn1_time({:generalTime, value}) do
    <<year::binary-size(4), month::binary-size(2), day::binary-size(2), hour::binary-size(2), minute::binary-size(2),
      second::binary-size(2), "Z">> = to_string(value)

    [y, m, d, h, min, s] = Enum.map([year, month, day, hour, minute, second], &String.to_integer/1)
    :calendar.datetime_to_gregorian_seconds({{y, m, d}, {h, min, s}})
  end

  @spec read_required!(String.t()) :: binary()
  defp read_required!(path) do
    case read_optional!(path) do
      nil -> fail!(path, "file is missing")
      content -> content
    end
  end

  # Paths are validated operator configuration, never IRC input.
  # sobelow_skip ["Traversal.FileModule"]
  @spec read_optional!(String.t()) :: binary() | nil
  defp read_optional!(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> File.read!(path)
      {:ok, _} -> fail!(path, "expected a regular readable file")
      {:error, :enoent} -> nil
      {:error, reason} -> raise File.Error, reason: reason, action: "read configuration resource", path: path
    end
  end

  @spec write_files!(list(), [String.t()]) :: :ok
  defp write_files!([], _created), do: :ok

  defp write_files!([{path, contents} | rest], created) do
    try do
      write_exclusive!(path, contents)
    rescue
      error ->
        remove_created(created)
        reraise error, __STACKTRACE__
    end

    write_files!(rest, [path | created])
  end

  # Paths are exclusively files created by this attempt from validated operator configuration.
  # sobelow_skip ["Traversal.FileModule"]
  @spec remove_created([String.t()]) :: :ok
  defp remove_created(paths), do: Enum.each(paths, &File.rm/1)

  # Only new files from this attempt are removed on failure.
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_exclusive!(String.t(), binary()) :: :ok
  defp write_exclusive!(path, contents) do
    File.mkdir_p!(Path.dirname(path))

    file =
      case File.open(path, [:write, :binary, :exclusive]) do
        {:ok, file} -> file
        {:error, reason} -> raise File.Error, reason: reason, action: "create configuration resource", path: path
      end

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(file, contents)
      :ok = :file.sync(file)
    rescue
      error ->
        File.rm(path)
        reraise error, __STACKTRACE__
    after
      File.close(file)
    end
  end

  @spec fail!(String.t(), String.t()) :: no_return()
  defp fail!(path, message), do: raise(Error, path: path, errors: [message])
end
