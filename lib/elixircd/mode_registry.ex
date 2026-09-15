defmodule ElixIRCd.ModeRegistry do
  @moduledoc """
  Defines the finite set of IRC mode identifiers used internally.

  Mode characters only exist as strings at IRC and configuration boundaries.
  Internal state uses the equivalent atoms without dynamically creating atoms
  from client input.
  """

  @user_modes [:B, :g, :H, :i, :o, :r, :R, :s, :w, :x, :Z]
  @channel_modes [
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
    :n,
    :O,
    :o,
    :p,
    :r,
    :R,
    :s,
    :t,
    :T,
    :u,
    :v,
    :z
  ]
  @membership_modes [:o, :v]

  @user_modes_by_character Map.new(@user_modes, &{Atom.to_string(&1), &1})
  @channel_modes_by_character Map.new(@channel_modes, &{Atom.to_string(&1), &1})
  @membership_modes_by_character Map.new(@membership_modes, &{Atom.to_string(&1), &1})
  @user_characters_by_mode Map.new(@user_modes, &{&1, Atom.to_string(&1)})
  @channel_characters_by_mode Map.new(@channel_modes, &{&1, Atom.to_string(&1)})
  @membership_characters_by_mode Map.new(@membership_modes, &{&1, Atom.to_string(&1)})

  @type user_mode :: :B | :g | :H | :i | :o | :r | :R | :s | :w | :x | :Z
  @type channel_mode ::
          :b
          | :C
          | :c
          | :d
          | :e
          | :I
          | :i
          | :j
          | :k
          | :l
          | :m
          | :M
          | :n
          | :O
          | :o
          | :p
          | :r
          | :R
          | :s
          | :t
          | :T
          | :u
          | :v
          | :z
  @type membership_mode :: :o | :v
  @type context :: :user | :channel | :membership
  @type mode :: user_mode() | channel_mode()

  @doc "Returns the supported modes for an internal mode context in wire order."
  @spec modes(context()) :: [mode()]
  def modes(:user), do: @user_modes
  def modes(:channel), do: @channel_modes
  def modes(:membership), do: @membership_modes

  @doc "Decodes a protocol character into a mode from the finite registry."
  @spec decode(context(), String.t()) :: {:ok, mode()} | :error
  def decode(:user, character), do: Map.fetch(@user_modes_by_character, character)
  def decode(:channel, character), do: Map.fetch(@channel_modes_by_character, character)
  def decode(:membership, character), do: Map.fetch(@membership_modes_by_character, character)

  @doc "Encodes a registered internal mode as its IRC protocol character."
  @spec encode(context(), mode()) :: {:ok, String.t()} | :error
  def encode(:user, mode), do: Map.fetch(@user_characters_by_mode, mode)
  def encode(:channel, mode), do: Map.fetch(@channel_characters_by_mode, mode)
  def encode(:membership, mode), do: Map.fetch(@membership_characters_by_mode, mode)

  @doc "Encodes a registered mode, raising when it does not belong to the context."
  @spec encode!(context(), mode()) :: String.t()
  def encode!(context, mode) do
    case encode(context, mode) do
      {:ok, character} -> character
      :error -> raise ArgumentError, "unsupported #{context} mode: #{inspect(mode)}"
    end
  end
end
