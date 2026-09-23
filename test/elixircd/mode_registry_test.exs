defmodule ElixIRCd.ModeRegistryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.ModeRegistry

  test "defines the complete mode sets in wire order" do
    assert ModeRegistry.modes(:user) == [:B, :g, :H, :i, :o, :r, :R, :s, :w, :x, :Z]

    assert ModeRegistry.modes(:channel) == [
             :b,
             :C,
             :c,
             :d,
             :e,
             :I,
             :i,
             :j,
             :k,
             :l,
             :m,
             :M,
             :N,
             :n,
             :O,
             :o,
             :p,
             :r,
             :R,
             :s,
             :t,
             :T,
             :U,
             :u,
             :v,
             :z
           ]

    assert ModeRegistry.modes(:membership) == [:o, :v]
  end

  test "round-trips every supported mode without losing case" do
    for context <- [:user, :channel, :membership], mode <- ModeRegistry.modes(context) do
      character = Atom.to_string(mode)
      assert {:ok, ^mode} = ModeRegistry.decode(context, character)
      assert {:ok, ^character} = ModeRegistry.encode(context, mode)
      assert character == ModeRegistry.encode!(context, mode)
    end

    assert {:ok, :i} = ModeRegistry.decode(:channel, "i")
    assert {:ok, :I} = ModeRegistry.decode(:channel, "I")
    assert {:ok, :r} = ModeRegistry.decode(:user, "r")
    assert {:ok, :R} = ModeRegistry.decode(:user, "R")
  end

  test "rejects unknown, malformed and cross-context identifiers" do
    for value <- ["?", "💥", "oo", ""] do
      assert :error = ModeRegistry.decode(:user, value)
      assert :error = ModeRegistry.decode(:channel, value)
    end

    assert :error = ModeRegistry.decode(:membership, "i")
    assert :error = ModeRegistry.encode(:user, :v)
    assert :error = ModeRegistry.encode(:membership, :i)
    assert :error = ModeRegistry.encode(:channel, "i")
    assert_raise ArgumentError, fn -> ModeRegistry.encode!(:membership, :i) end
  end
end
