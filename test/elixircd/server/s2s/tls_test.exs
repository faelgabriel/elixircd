defmodule ElixIRCd.Server.S2S.TLSTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.TLS

  defmodule PeerTransport do
    def peername(:peer), do: {:ok, {{192, 0, 2, 44}, 7443}}
    def peercert(:peer), do: {:ok, <<1, 2, 3, 4>>}
  end

  defmodule NoCertificateTransport do
    def peername(:peer), do: {:ok, {{192, 0, 2, 45}, 7444}}
    def peercert(:peer), do: {:error, :no_peercert}
  end

  test "builds a dedicated mutual TLS listener and client policy" do
    s2s = [
      listener: [
        ip: {127, 0, 0, 1},
        port: 7000,
        keyfile: "key.pem",
        certfile: "cert.pem",
        cacertfile: "ca.pem",
        versions: [:"tlsv1.2"],
        backlog: 32
      ]
    ]

    listener = TLS.listener_options(s2s)
    transport = listener[:transport_options]
    assert listener[:port] == 7000
    assert transport[:verify] == :verify_peer
    assert transport[:fail_if_no_peer_cert]
    assert transport[:ip] == {127, 0, 0, 1}
    assert transport[:backlog] == 32

    client = TLS.client_options(s2s, address: "parent.example", sni: "parent.example", bind_ip: {127, 0, 0, 1})
    assert client[:server_name_indication] == ~c"parent.example"
    assert client[:verify] == :verify_peer
    assert client[:ip] == {127, 0, 0, 1}
  end

  test "matches certificate pins without treating a pin as an identity claim" do
    fingerprint = TLS.fingerprint(<<1, 2, 3>>)
    assert byte_size(fingerprint) == 64
    assert TLS.pin_allowed?(fingerprint, [String.upcase(fingerprint)])
    refute TLS.pin_allowed?(fingerprint, [String.duplicate("0", 64)])
  end

  test "enforces optional child IP and CIDR admission" do
    assert TLS.address_allowed?({192, 0, 2, 7}, ["192.0.2.0/24"])
    assert TLS.address_allowed?({192, 0, 2, 7}, ["192.0.2.7"])
    refute TLS.address_allowed?({192, 0, 3, 7}, ["192.0.2.0/24"])
    assert TLS.address_allowed?({192, 0, 3, 7}, [])
  end

  test "uses the remote peer endpoint when collecting certificate identity" do
    assert {:ok, %{address: {192, 0, 2, 44}, port: 7443, certfp: certfp}} =
             TLS.peer_info(PeerTransport, :peer)

    assert certfp == TLS.fingerprint(<<1, 2, 3, 4>>)
  end

  test "fails closed when the TLS socket has no peer certificate" do
    assert {:error, :no_peercert} = TLS.peer_info(NoCertificateTransport, :peer)
  end
end
