defmodule ElixIRCd.Config.TypesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.Config.Types

  for {type, valid, invalid} <- [
        {:boolean, [true, false], [nil, "true", 1]},
        {:positive_integer, [1, 200], [0, -1, 1.5, "1"]},
        {:non_negative_integer, [0, 1], [-1, 0.1, nil]},
        {:positive_number, [1, 0.5], [0, -1, "0.5"]},
        {:port, [1, 65_535], [0, 65_536, 1.5]},
        {:timeout, [0, 100, :infinity], [-1, "infinity"]},
        {:connection_limit, [0, 10, :infinity], [nil, -1, true]},
        {:text, ["Network", "Hello world"], ["", "   ", "hello\nworld", <<255>>]},
        {:token, ["password", "root"], ["", "two words", ":prefix"]},
        {:path, ["data/cloak.key", "/tmp/key"], ["", nil, "bad\0path"]},
        {:hostname_label, ["localhost", "irc-test"], ["-invalid", "invalid-", "a.b"]},
        {:hostname, ["localhost", "irc.example.org"], ["host..test", "bad host", nil]},
        {:cloak_prefix, ["test", String.duplicate("x", 54)], [String.duplicate("x", 55), ".bad"]},
        {:url, ["https://api.example.org/v3", "http://localhost:3000"],
         [nil, "https://example.com:abc", "http://example.com:65536"]},
        {:email, ["admin@example.org"], ["not-an-email", "a@b", "a\nb@example.org"]},
        {:nickname, ["Nick_123", "[nick]"], ["1nick", "bad nick", ""]},
        {:mask, ["*!*@*.example.org", "nick!ident@::1"], ["bad mask", "nick!ident", nil]},
        {:ip, ["127.0.0.1", "::1"], ["999.0.0.1", "127.1", <<255>>, nil]},
        {:ip_tuple, [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}], [{256, 0, 0, 1}, {1, 2, 3}, :loopback]},
        {:cidr, ["192.0.2.0/24", "::/0", "::1/128"], ["127.0.0.1", "::/129", "127.0.0.1/a", "127.0.0.1/01", nil]},
        {:ip_or_cidr, ["127.0.0.1", "2001:db8::/32"], ["localhost", false]},
        {:channel_pattern, ["#channel", "&local", ~r/^#opers$/], ["channel", "#with spaces", 42]},
        {:motd, [nil, "", "Hello\nworld", {:ok, "MOTD"}], [{:error, :enoent}, {:ok, nil}, <<0>>]}
      ] do
    test "#{type} accepts its documented values and rejects malformed ones" do
      for value <- unquote(Macro.escape(valid)), do: assert(Types.valid?(unquote(type), value), inspect(value))
      for value <- unquote(Macro.escape(invalid)), do: refute(Types.valid?(unquote(type), value), inspect(value))
    end
  end

  test "Argon2 hashes must be structurally valid with bounded parameters and decodable salt and hash" do
    hash = "$argon2id$v=19$m=4096,t=2,p=4$0Ikum7IgbC2CkId/UJQE7A$n1YVbtPj1nP4EfdL771tPCS1PmK+Q364g14ScJzBaSg"
    assert Types.valid?(:argon2_hash, hash)

    for malformed <- [
          nil,
          "plain-secret",
          String.replace(hash, "m=4096", "m=1"),
          String.replace(hash, "t=2", "t=0"),
          String.replace(hash, "p=4", "p=17"),
          String.replace(hash, "0Ikum7IgbC2CkId/UJQE7A", "A"),
          String.replace(hash, "0Ikum7IgbC2CkId/UJQE7A", "AAAA")
        ] do
      refute Types.valid?(:argon2_hash, malformed)
    end
  end
end
