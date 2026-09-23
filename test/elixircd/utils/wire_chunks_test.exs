defmodule ElixIRCd.Utils.WireChunksTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Message
  alias ElixIRCd.Utils.WireChunks

  test "rejects an individual word that cannot fit in an IRC line" do
    builder = fn words, continued? ->
      %Message{
        command: "CAP",
        params: ["*", "LS"] ++ if(continued?, do: ["*"], else: []),
        trailing: Enum.join(words, " ")
      }
    end

    assert_raise ArgumentError, ~r/cannot fit/, fn ->
      WireChunks.split([String.duplicate("x", 600)], builder)
    end
  end
end
