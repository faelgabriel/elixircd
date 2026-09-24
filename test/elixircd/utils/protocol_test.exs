defmodule ElixIRCd.Utils.ProtocolTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Message
  alias ElixIRCd.Utils.Protocol

  describe "channel_name?/1" do
    test "returns true for channel names" do
      assert true == Protocol.channel_name?("#elixir")
      assert true == Protocol.channel_name?("&local")
    end

    test "returns false for non-channel names" do
      assert false == Protocol.channel_name?("elixir")
      assert false == Protocol.channel_name?("@invalid")
    end

    test "returns false for empty strings" do
      assert false == Protocol.channel_name?("")
    end
  end

  describe "service_name?/1" do
    test "returns true for valid service names" do
      assert Protocol.service_name?("NICKSERV") == true
      assert Protocol.service_name?("nickserv") == true
      assert Protocol.service_name?("CHANSERV") == true
      assert Protocol.service_name?("chanserv") == true
    end

    test "returns false for invalid service names" do
      assert Protocol.service_name?("INVALID") == false
    end
  end

  describe "irc_operator?/1" do
    test "returns true for irc operator" do
      user = build(:user, %{modes: [:o]})
      assert true == Protocol.irc_operator?(user)
    end

    test "returns false for non-irc operator" do
      user = build(:user, %{modes: []})
      assert false == Protocol.irc_operator?(user)
    end
  end

  describe "channel_operator?/1" do
    test "returns true for channel operator" do
      user_channel = build(:user_channel, %{modes: [:o]})
      assert true == Protocol.channel_operator?(user_channel)
    end

    test "returns false for non-channel operator" do
      user_channel = build(:user_channel, %{modes: []})
      assert false == Protocol.channel_operator?(user_channel)
    end
  end

  describe "channel_voice?/1" do
    test "returns true for channel voice" do
      user_channel = build(:user_channel, %{modes: [:v]})
      assert true == Protocol.channel_voice?(user_channel)
    end

    test "returns false for non-channel voice" do
      user_channel = build(:user_channel, %{modes: []})
      assert false == Protocol.channel_voice?(user_channel)
    end
  end

  describe "match_user_mask?/2" do
    test "matches account extbans only against authenticated accounts" do
      authenticated = build(:user, identified_as: "Bob")
      unauthenticated = build(:user, nick: "bob", identified_as: nil)

      assert Protocol.match_user_mask?(authenticated, "$a:bob")
      assert Protocol.match_user_mask?(authenticated, "$a:b*")
      refute Protocol.match_user_mask?(unauthenticated, "$a:bob")
      refute Protocol.match_user_mask?(authenticated, "$m:*!*@*")
    end

    test "matches realname extbans with IRC glob semantics" do
      user = build(:user, realname: "Alice Example")
      assert Protocol.match_user_mask?(user, "$r:alice*")
      assert Protocol.match_user_mask?(user, "$r:*Example")
      refute Protocol.match_user_mask?(user, "$r:Bob*")
      assert Protocol.normalize_mask("$r:Alice*") == "$r:Alice*"
    end

    test "matches mute extbans against the inner user mask" do
      user = build(:user, nick: "Muted", ident: "ident", hostname: "host")

      assert Protocol.match_mute_mask?(user, "$m:muted!*@*")
      refute Protocol.match_mute_mask?(user, "$m:other!*@*")
      refute Protocol.match_mute_mask?(user, "$a:muted")
    end

    test "keeps nickname case mapping separate from ident and hostname" do
      user = build(:user, nick: "Bar[", ident: "~User", hostname: "Host[.Example")
      assert Protocol.match_user_mask?(user, "bAR{!~uSER@hOST[.example")
      refute Protocol.match_user_mask?(user, "*!^User@*")
      refute Protocol.match_user_mask?(user, "*!*@Host{.Example")
      refute Protocol.match_user_mask?(user, "*!~User@Host[.EXAMPLÉ")
      assert Protocol.match_user_mask?(user, "~uSER@hOST[.example")
    end

    test "matches the placeholder of an unregistered user" do
      user = build(:user, registered: false, nick: nil, ident: nil)
      assert Protocol.match_user_mask?(user, "*")
      refute Protocol.match_user_mask?(user, "nick!user@host")
    end

    test "treats regex metacharacters in masks literally" do
      user = build(:user, nick: "nick", ident: "user", hostname: "host")

      for mask <- ["*!*@([", "*!*@h(st", "*!*@host|other", "*!*@host$", "*!*@h[oa]st", "*!*@host\\"] do
        refute Protocol.match_user_mask?(user, mask)
      end

      literal_user = build(:user, nick: "[nick]", ident: "user", hostname: "([")
      assert Protocol.match_user_mask?(literal_user, "[nick]!*@([")
    end

    test "anchors masks and supports question marks and repeated stars" do
      user = build(:user, nick: "nick", ident: "user", hostname: "host")
      refute Protocol.match_user_mask?(user, "ick!user@hos")
      assert Protocol.match_user_mask?(user, "n?ck!**@h??t")
      assert Protocol.match_user_mask?(user, "*")
      refute Protocol.match_user_mask?(user, String.duplicate("*a", 100) <> "b")
    end

    test "matches user mask" do
      user = build(:user, nick: "nick", ident: "~user", hostname: "host")

      assert true == Protocol.match_user_mask?(user, "nick!~user@host")
      assert true == Protocol.match_user_mask?(user, "nick!~user@*")
      assert true == Protocol.match_user_mask?(user, "nick!*@host")
      assert true == Protocol.match_user_mask?(user, "nick!*@*")
      assert true == Protocol.match_user_mask?(user, "*!~user@host")
      assert true == Protocol.match_user_mask?(user, "*!~user@*")
      assert true == Protocol.match_user_mask?(user, "*!*@host")
      assert true == Protocol.match_user_mask?(user, "*!*@*")
      assert true == Protocol.match_user_mask?(user, "n*!*@*")
      assert true == Protocol.match_user_mask?(user, "*!~u*@host")
      assert true == Protocol.match_user_mask?(user, "*!~user@h*")
      assert true == Protocol.match_user_mask?(user, "*k!*@*")
      assert true == Protocol.match_user_mask?(user, "*!~*r@host")
      assert true == Protocol.match_user_mask?(user, "*!~user@*t")
    end

    test "does not match user mask" do
      user = build(:user, nick: "nick", ident: "~user", hostname: "host")

      assert false == Protocol.match_user_mask?(user, "difnick!~user@host")
      assert false == Protocol.match_user_mask?(user, "difnick!~user@*")
      assert false == Protocol.match_user_mask?(user, "difnick!*@host")
      assert false == Protocol.match_user_mask?(user, "difnick!*@*")
      assert false == Protocol.match_user_mask?(user, "*!~difuser@host")
      assert false == Protocol.match_user_mask?(user, "*!~difuser@*")
      assert false == Protocol.match_user_mask?(user, "*!*@difhost")
    end

    test "matches user mask with cloaked hostname when user has +x mode" do
      user =
        build(:user,
          nick: "nick",
          ident: "~user",
          hostname: "real.host.com",
          modes: [:x],
          cloaked_hostname: "elixir-ABC123.example.com"
        )

      # Should match against cloaked hostname
      assert true == Protocol.match_user_mask?(user, "nick!~user@elixir-ABC123.example.com")
      assert true == Protocol.match_user_mask?(user, "*!*@elixir-*.example.com")
      assert true == Protocol.match_user_mask?(user, "*!*@*.example.com")

      # Should NOT match against real hostname (user has +x)
      assert false == Protocol.match_user_mask?(user, "nick!~user@real.host.com")
      assert false == Protocol.match_user_mask?(user, "*!*@real.host.com")
      assert false == Protocol.match_user_mask?(user, "*!*@*.host.com")
    end

    test "matches user mask with real hostname when user does not have +x mode" do
      user =
        build(:user,
          nick: "nick",
          ident: "~user",
          hostname: "real.host.com",
          modes: [],
          cloaked_hostname: "elixir-ABC123.example.com"
        )

      # Should match against real hostname (no +x mode)
      assert true == Protocol.match_user_mask?(user, "nick!~user@real.host.com")
      assert true == Protocol.match_user_mask?(user, "*!*@real.host.com")
      assert true == Protocol.match_user_mask?(user, "*!*@*.host.com")

      # Should NOT match against cloaked hostname (not using it)
      assert false == Protocol.match_user_mask?(user, "nick!~user@elixir-ABC123.example.com")
      assert false == Protocol.match_user_mask?(user, "*!*@elixir-*.example.com")
    end
  end

  describe "mask_key/1" do
    setup do
      settings = Application.fetch_env!(:elixircd, :settings)
      on_exit(fn -> Application.put_env(:elixircd, :settings, settings) end)
      {:ok, settings: settings}
    end

    test "folds only the nickname with the configured IRC casemapping", %{settings: settings} do
      for {mapping, expected_nick} <- [
            {:ascii, "nick{"},
            {:strict_rfc1459, "nick["},
            {:rfc1459, "nick["}
          ] do
        Application.put_env(:elixircd, :settings, Keyword.put(settings, :case_mapping, mapping))

        assert Protocol.mask_key("Nick{!Id{|}~@Host{|}~") == "#{expected_nick}!id{|}~@host{|}~"
        refute Protocol.mask_key("Nick{!Id{|}~@Host{|}~") == Protocol.mask_key("Nick{!Id[\\]^@Host[\\]^")
      end
    end

    test "normalizes complete and abbreviated hostmasks, preserving extban type", %{settings: settings} do
      Application.put_env(:elixircd, :settings, Keyword.put(settings, :case_mapping, :rfc1459))

      assert Protocol.mask_key("Nick") == Protocol.mask_key("nICK!*@*")
      assert Protocol.mask_key("$a:Account{") == "$a:account["
      assert Protocol.mask_key("$r:RealName") == "$r:realname"
      assert Protocol.mask_key("$m:Nick!Id@HOST") == "$m:nick!id@host"
      refute Protocol.mask_key("$m:Nick!Id@HOST") == Protocol.mask_key("Nick!Id@HOST")
    end
  end

  describe "user_reply/1" do
    test "returns reply for registered user" do
      user = build(:user)
      reply = Protocol.user_reply(user)

      assert reply == user.nick
    end

    test "returns reply for user not registered" do
      user = build(:user, %{registered: false})
      reply = Protocol.user_reply(user)

      assert reply == "*"
    end
  end

  describe "user_mask/1" do
    test "builds user mask with ident" do
      user = build(:user, nick: "nick", ident: "~username", hostname: "host", registered: true)
      assert "nick!~username@host" == Protocol.user_mask(user)
    end

    test "builds a user mask and truncates ident" do
      user =
        build(:user, nick: "nick", ident: "useriduseriduserid", hostname: "host", registered: true)

      assert "nick!useriduser@host" == Protocol.user_mask(user)
    end

    test "builds a user mask for user not registered" do
      user = build(:user, registered: false)
      assert "*" == Protocol.user_mask(user)
    end
  end

  describe "user_mask/2" do
    test "builds a registration mask with placeholders for missing fields" do
      user = build(:user, registered: false, nick: nil, ident: nil, hostname: "real.host")

      assert "*!*@real.host" == Protocol.user_mask(user, :registration)
    end

    test "prefers the precomputed cloak and truncates the ident" do
      user =
        build(:user,
          registered: false,
          nick: "nick",
          ident: "longusername",
          hostname: "real.host",
          cloaked_hostname: "cloak.host"
        )

      assert "nick!longuserna@cloak.host" == Protocol.user_mask(user, :registration)
    end
  end

  describe "user_host/2" do
    test "returns the truncated ident and public hostname" do
      user = build(:user, ident: "longusername", hostname: "real.host")

      assert "longuserna@real.host" == Protocol.user_host(user)
    end

    test "shows a cloaked hostname publicly and the real hostname to an operator" do
      user = build(:user, ident: "~user", hostname: "real.host", cloaked_hostname: "cloak.host", modes: [:x])
      operator = build(:user, modes: [:o])

      assert "~user@cloak.host" == Protocol.user_host(user)
      assert "~user@real.host" == Protocol.user_host(user, operator)
    end
  end

  describe "parse_targets/1" do
    test "parses channel list" do
      assert {:channels, ["#elixir", "#elixircd"]} == Protocol.parse_targets("#elixir,#elixircd")
    end

    test "parses user list" do
      assert {:users, ["elixir", "elixircd"]} == Protocol.parse_targets("elixir,elixircd")
    end

    test "returns error" do
      assert {:error, "Invalid list of targets"} == Protocol.parse_targets("elixir,#elixircd")
    end
  end

  describe "normalize_mask/1" do
    test "normalizes user mask" do
      assert "nick!user@host" == Protocol.normalize_mask("nick!user@host")
      assert "nick!user@*" == Protocol.normalize_mask("nick!user")
      assert "nick!*@*" == Protocol.normalize_mask("nick")
      assert "nick!*@host" == Protocol.normalize_mask("nick!@host")
      assert "*!user@host" == Protocol.normalize_mask("user@host")
      assert "*!*@host" == Protocol.normalize_mask("!@host")
      assert "*!*@host" == Protocol.normalize_mask("@host")
      assert "*!*@@" == Protocol.normalize_mask("@@")
      assert "*!!@*" == Protocol.normalize_mask("!!")
      assert "**!*@*" == Protocol.normalize_mask("**")
      assert "*!*@*" == Protocol.normalize_mask("*")
      assert "*!*@*" == Protocol.normalize_mask("!")
      assert "*!*@*" == Protocol.normalize_mask("@")
      assert "*!*@*" == Protocol.normalize_mask("*!@*")
      assert "$a:Account" == Protocol.normalize_mask("$a:Account")
      assert "$m:nick!*@*" == Protocol.normalize_mask("$m:nick")
    end
  end

  describe "chunk_message_words/3" do
    test "chunks names without splitting a token" do
      message = %Message{command: :rpl_namreply, params: ["nick", "=", "#channel"]}

      chunks = Protocol.chunk_message_words(message, ["@first", "+second", "third"], 35)

      assert Enum.map(chunks, & &1.trailing) == ["@first", "+second", "third"]
      assert Enum.all?(chunks, &(not String.contains?(&1.trailing, "\n")))
      assert Enum.all?(chunks, &(wire_size(&1) <= 35))
    end

    test "uses a protocol-safe fallback when an extended NAMES token cannot fit" do
      message = %Message{
        prefix: String.duplicate("s", 63),
        command: :rpl_namreply,
        params: [String.duplicate("n", 30), "=", "#channel"]
      }

      extended = "@Nick!ident@" <> String.duplicate("h", 400)
      [chunk] = Protocol.chunk_message_words(message, [{extended, "@Nick"}])

      assert chunk.trailing == "@Nick"
      assert wire_size(chunk) <= 512
    end

    test "rejects a first protocol token that cannot fit" do
      message = %Message{command: "NOTICE", params: ["target"]}

      assert_raise ArgumentError, ~r/protocol token/, fn ->
        Protocol.chunk_message_words(message, [String.duplicate("x", 40)], 20)
      end
    end

    test "rejects a later protocol token that cannot fit on a fresh line" do
      message = %Message{command: "NOTICE", params: ["target"]}

      assert_raise ArgumentError, ~r/protocol token/, fn ->
        Protocol.chunk_message_words(message, ["a", String.duplicate("x", 40)], 20)
      end
    end
  end

  describe "chunk_message_text/3" do
    test "preserves all graphemes while bounding every serialized line" do
      message = %Message{
        prefix: "NickServ!service@irc.test",
        command: "NOTICE",
        params: ["recipient"]
      }

      text = String.duplicate("😊", 400)
      chunks = Protocol.chunk_message_text(message, text)

      assert Enum.map_join(chunks, & &1.trailing) == text
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(wire_size(&1) <= 512))
    end

    test "rejects an initial grapheme when message overhead consumes the budget" do
      message = %Message{command: "NOTICE", params: ["target"]}

      assert_raise ArgumentError, ~r/no room for one UTF-8 grapheme/, fn ->
        Protocol.chunk_message_text(message, "😊", 20)
      end
    end

    test "rejects a larger next grapheme that cannot fit by itself" do
      message = %Message{command: "NOTICE", params: ["target"]}
      overhead = byte_size(Message.unparse_unbounded!(%{message | trailing: ""}))

      assert_raise ArgumentError, ~r/no room for one UTF-8 grapheme/, fn ->
        Protocol.chunk_message_text(message, "a😊", overhead + 1)
      end
    end
  end

  describe "match_glob?/2" do
    test "rejects non-binary values" do
      refute Protocol.match_glob?(nil, "*")
      refute Protocol.match_glob?("value", nil)
    end
  end

  describe "match_ascii_glob?/2" do
    test "folds ASCII without treating RFC 1459 nickname equivalents as equal" do
      assert Protocol.match_ascii_glob?("Host^Name", "host^*")
      refute Protocol.match_ascii_glob?("Host^Name", "host~*")
      refute Protocol.match_ascii_glob?(nil, "*")
      refute Protocol.match_ascii_glob?("Host^Name", nil)
    end
  end

  describe "valid_mask_format?/1" do
    test "validates correct masks" do
      # Valid full masks
      assert Protocol.valid_mask_format?("nick!user@host.com")
      assert Protocol.valid_mask_format?("nick!user@*")
      assert Protocol.valid_mask_format?("nick!*@host.com")
      assert Protocol.valid_mask_format?("*!user@host.com")
      assert Protocol.valid_mask_format?("nick")
      assert Protocol.valid_mask_format?("user@host.com")
      assert Protocol.valid_mask_format?("nick!user")
      assert Protocol.valid_mask_format?("nick*!user@host.com")
      assert Protocol.valid_mask_format?("nick!*user@host.com")
      assert Protocol.valid_mask_format?("nick!user@*.com")
      assert Protocol.valid_mask_format?("?ick!user@host.com")
      assert Protocol.valid_mask_format?("nick!user@host.?om")

      # Wildcards
      assert Protocol.valid_mask_format?("*")
      assert Protocol.valid_mask_format?("?")
      assert Protocol.valid_mask_format?("*!*@*")
      assert Protocol.valid_mask_format?("?!?@?")

      # Mixed wildcards and characters
      assert Protocol.valid_mask_format?("nick*")
      assert Protocol.valid_mask_format?("*nick")
      assert Protocol.valid_mask_format?("ni?k")

      # Special IRC characters
      assert Protocol.valid_mask_format?("nick[test]")
      assert Protocol.valid_mask_format?("nick\\test")
      assert Protocol.valid_mask_format?("nick`test")
      assert Protocol.valid_mask_format?("nick_test")
      assert Protocol.valid_mask_format?("nick^test")
      assert Protocol.valid_mask_format?("nick{test}")
      assert Protocol.valid_mask_format?("nick|test")

      # Dots and hyphens
      assert Protocol.valid_mask_format?("nick!user@host-name.example.com")
      assert Protocol.valid_mask_format?("nick!user@192.168.1.1")
    end

    test "rejects invalid masks" do
      # Empty mask
      refute Protocol.valid_mask_format?("")

      # Invalid characters
      refute Protocol.valid_mask_format?("nick!user@host<.com")
      refute Protocol.valid_mask_format?("nick!user@host>.com")
      refute Protocol.valid_mask_format?("nick!user@host(.com")
      refute Protocol.valid_mask_format?("nick!user@host).com")

      # Non-string input
      refute Protocol.valid_mask_format?(123)
      refute Protocol.valid_mask_format?(nil)
      refute Protocol.valid_mask_format?(:atom)

      # Too long parts
      long_part = String.duplicate("a", 65)
      refute Protocol.valid_mask_format?("#{long_part}!user@host.com")
      refute Protocol.valid_mask_format?("nick!#{long_part}@host.com")
      refute Protocol.valid_mask_format?("nick!user@#{long_part}")
    end
  end

  describe "display_hostname/2" do
    test "returns cloaked hostname for user with +x mode" do
      user = build(:user, modes: [:x], cloaked_hostname: "elixir-ABC123.example.com", hostname: "real.example.com")
      result = Protocol.display_hostname(user, nil)
      assert result == "elixir-ABC123.example.com"
    end

    test "returns real hostname when operator is viewing" do
      operator = build(:user, modes: [:o])

      target_user =
        build(:user, modes: [:x], cloaked_hostname: "elixir-ABC123.example.com", hostname: "real.example.com")

      result = Protocol.display_hostname(target_user, operator)
      assert result == "real.example.com"
    end

    test "returns real hostname when user does not have +x mode" do
      user = build(:user, modes: [], hostname: "real.example.com")
      result = Protocol.display_hostname(user, nil)
      assert result == "real.example.com"
    end
  end

  defp wire_size(message) do
    message
    |> Map.put(:tags, %{})
    |> Message.unparse_unbounded!()
    |> byte_size()
  end
end
