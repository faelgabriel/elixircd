defmodule ElixIRCd.ServerLink.UserPayload do
  @moduledoc "Validates the public, PID-free user record carried over a server link."

  alias ElixIRCd.Config.Types
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Tables.User

  @fields ~w(uid nick ident hostname cloaked_hostname realname modes account away registered_at)
  @modes ModeRegistry.modes(:user) |> Enum.map(&Atom.to_string/1)
  @max_away_characters 400
  @max_away_bytes @max_away_characters * 4

  @type wire_user :: %{required(String.t()) => String.t() | [String.t()] | nil}

  @doc "Returns a random session UID; the home server ID is carried separately."
  @spec new_uid() :: String.t()
  def new_uid, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  @doc "Checks the UTF-8 and character limits of a local AWAY reason on the wire."
  @spec valid_away?(term()) :: boolean()
  def valid_away?(nil), do: true

  def valid_away?(value) when is_binary(value) do
    byte_size(value) <= @max_away_bytes and String.valid?(value) and
      String.length(value) <= @max_away_characters and
      not String.contains?(value, ["\r", "\n", <<0>>])
  end

  def valid_away?(_value), do: false

  @doc "Builds the wire representation of a registered local user."
  @spec from_local(User.t(), String.t()) :: wire_user()
  def from_local(%User{registered: true} = user, uid) do
    %{
      "uid" => uid,
      "nick" => user.nick,
      "ident" => user.ident,
      "hostname" => user.hostname,
      "cloaked_hostname" => user.cloaked_hostname,
      "realname" => user.realname,
      "modes" => Enum.map(user.modes, &ModeRegistry.encode!(:user, &1)),
      "account" => user.identified_as,
      "away" => user.away_message,
      "registered_at" => DateTime.to_iso8601(user.registered_at)
    }
  end

  @doc "Builds a public user view for IRC formatting and visibility checks."
  @spec public_view(map()) :: map()
  def public_view(payload) do
    modes =
      Enum.map(payload["modes"], fn character ->
        {:ok, mode} = ModeRegistry.decode(:user, character)
        mode
      end)

    %{
      registered: true,
      pid: nil,
      nick: payload["nick"],
      ident: payload["ident"],
      hostname: payload["hostname"],
      cloaked_hostname: payload["cloaked_hostname"],
      realname: payload["realname"],
      identified_as: payload["account"],
      away_message: payload["away"],
      modes: modes
    }
  end

  @doc "Rejects unknown keys, unsafe strings, noncanonical UIDs and modes."
  @spec validate(term()) :: :ok | {:error, :invalid_user}
  def validate(payload) when is_map(payload) do
    valid =
      Enum.sort(Map.keys(payload)) == Enum.sort(@fields) and
        identity?(payload) and profile?(payload) and status?(payload)

    if valid, do: :ok, else: {:error, :invalid_user}
  end

  def validate(_payload), do: {:error, :invalid_user}

  @doc "Checks the canonical 128-bit hexadecimal user or epoch identifier."
  @spec uid?(term()) :: boolean()
  def uid?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)

  defp identity?(payload) do
    uid?(payload["uid"]) and
      Types.valid?(:nickname, payload["nick"]) and byte_size(payload["nick"]) <= 64 and
      short_text?(payload["ident"], 64) and short_text?(payload["hostname"], 255)
  end

  defp profile?(payload) do
    optional_text?(payload["cloaked_hostname"], 255) and
      short_text?(payload["realname"], 300) and modes?(payload["modes"])
  end

  defp status?(payload) do
    optional_text?(payload["account"], 64) and
      valid_away?(payload["away"]) and timestamp?(payload["registered_at"])
  end

  defp short_text?(value, max), do: Types.valid?(:text, value) and byte_size(value) <= max
  defp optional_text?(nil, _max), do: true
  defp optional_text?(value, max), do: short_text?(value, max)

  defp modes?(modes) when is_list(modes) do
    Enum.all?(modes, &(&1 in @modes)) and length(modes) == length(Enum.uniq(modes))
  end

  defp modes?(_modes), do: false

  defp timestamp?(value) when is_binary(value) do
    match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp timestamp?(_value), do: false
end
