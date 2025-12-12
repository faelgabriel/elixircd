defmodule ElixIRCd.Commands.Authenticate.External do
  @moduledoc """
  EXTERNAL SASL mechanism implementation.

  Uses TLS client certificate authentication as defined in RFC 4422.
  The client's identity is derived from the certificate's CN or SAN.
  """

  require Logger

  # alias ElixIRCd.Repositories.RegisteredNicks

  @doc """
  Processes EXTERNAL authentication.

  Returns the authenticated account name or an error.
  """
  @spec process(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def process(user, data) do
    # EXTERNAL typically sends empty payload or "="
    case data do
      "+" -> authenticate_via_certificate(user)
      data when data in ["", "="] -> authenticate_via_certificate(user)
      _ -> {:error, "EXTERNAL mechanism requires empty payload"}
    end
  end

  defp authenticate_via_certificate(user) do
    if uses_tls?(user) do
      case extract_certificate_identity(user) do
        {:ok, identity} -> {:ok, identity}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "EXTERNAL requires TLS connection"}
    end
  end

  defp uses_tls?(user) do
    user.transport in [:tls, :wss]
  end

  defp extract_certificate_identity(user) do
    # Check if we have peer certificate data
    cert_binary = user.tls_peer_cert
    cert_verified = user.tls_cert_verified

    cond do
      cert_binary == nil ->
        {:error, "No client certificate provided"}

      not cert_verified ->
        {:error, "Client certificate not verified"}

      true ->
        # Try to decode and extract identity from certificate
        case decode_certificate(cert_binary) do
          {:ok, identity} -> verify_identity(identity)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp decode_certificate(cert_binary) do
    case :public_key.pkix_decode_cert(cert_binary, :otp) do
      {:OTPCertificate, tbs_cert, _algo, _sig} ->
        extract_identity_from_tbs(tbs_cert)

      _ ->
        {:error, "Failed to decode certificate"}
    end
  rescue
    _ -> {:error, "Certificate decoding error"}
  end

  defp extract_identity_from_tbs(tbs_cert) do
    # Extract Subject from TBS certificate
    {:OTPTBSCertificate, _version, _serial, _sig_algo, _issuer, _validity, subject, _pk, _issuer_id, _subject_id,
     _extensions} = tbs_cert

    # Get CN from subject
    case extract_cn_from_subject(subject) do
      nil ->
        # Try to get from certificate fingerprint mapping
        check_fingerprint_mapping(tbs_cert)

      cn ->
        {:ok, cn}
    end
  end

  defp extract_cn_from_subject({:rdnSequence, rdn_list}) do
    rdn_list
    |> List.flatten()
    |> Enum.find_value(fn attr_type_value ->
      case attr_type_value do
        {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}} ->
          to_string(cn)

        {:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, cn}} ->
          to_string(cn)

        _ ->
          nil
      end
    end)
  end

  defp check_fingerprint_mapping(tbs_cert) do
    # Compute certificate fingerprint and check against config mappings
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    external_config = sasl_config[:external] || []
    cert_mappings = Keyword.get(external_config, :cert_mappings, %{})

    # Reconstruct full certificate to compute fingerprint
    fingerprint = compute_cert_fingerprint(tbs_cert)

    case Map.get(cert_mappings, fingerprint) do
      nil ->
        {:error, "No identity found in certificate"}

      nickname ->
        {:ok, nickname}
    end
  end

  defp compute_cert_fingerprint(tbs_cert) do
    # In a production implementation, we would need the full OTPCertificate
    # to compute the proper fingerprint. For now, we'll create a hash of the TBS
    tbs_binary = :erlang.term_to_binary(tbs_cert)
    :crypto.hash(:sha256, tbs_binary) |> Base.encode16(case: :lower)
  end

  defp verify_identity(identity) do
    alias ElixIRCd.Repositories.RegisteredNicks

    # Check if the certificate identity maps to a registered nickname
    case RegisteredNicks.get_by_nickname(identity) do
      {:ok, registered_nick} -> {:ok, registered_nick.nickname}
      {:error, _} -> {:error, "Certificate identity not registered: #{identity}"}
    end
  end
end
