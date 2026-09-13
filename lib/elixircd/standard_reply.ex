defmodule ElixIRCd.StandardReply do
  @moduledoc """
  Structured IRCv3 FAIL, WARN and NOTE replies.

  Codes are interpreted together with their command, case-insensitively. Unknown codes are allowed; callers must reuse
  codes defined by the relevant IRCv3 spec. Context contains zero or more middle parameters, never the recipient
  nickname.

  This module represents and validates replies without sending them or negotiating capabilities. Dispatcher handles
  delivery, including optional legacy fallbacks, service prefixes, labels and server-time. Message handles IRC
  serialization.
  """

  alias ElixIRCd.Message

  @enforce_keys [:type, :command, :code, :description]
  defstruct [:type, :command, :code, :description, context: []]

  @type t :: %__MODULE__{
          type: :fail | :warn | :note,
          command: String.t(),
          code: String.t(),
          description: String.t(),
          context: [String.t()]
        }

  @doc """
  Converts a reply to the common IRC message representation without applying policy.
  """
  @spec to_message(t()) :: Message.t()
  def to_message(%__MODULE__{} = reply) do
    type = type_command(reply.type)
    validate_params!([reply.command, reply.code | reply.context])
    validate_description!(reply.description)

    %Message{
      command: type,
      params: [String.upcase(reply.command), String.upcase(reply.code) | reply.context],
      trailing: reply.description
    }
  end

  @doc """
  Fits a prepared standard reply into the IRC 512-byte limit, excluding tags. Only the description is shortened, at
  UTF-8 boundaries. Structured parameters are never silently changed. Other IRC messages pass through unchanged.
  """
  @spec fit_message(Message.t()) :: Message.t()
  def fit_message(%Message{command: type, params: params, trailing: nil} = message)
      when type in ["FAIL", "WARN", "NOTE"] and length(params) >= 3 do
    {context, [description]} = Enum.split(params, -1)
    fit_message(%{message | params: context, trailing: description})
  end

  def fit_message(%Message{command: type, trailing: description} = message) when type in ["FAIL", "WARN", "NOTE"] do
    validate_params!(message.params)
    validate_description!(description)

    overhead = byte_size(Message.unparse!(%{message | tags: %{}, trailing: ""}))
    available = 512 - overhead

    {first_codepoint, _rest} = String.next_codepoint(description)

    if available < byte_size(first_codepoint) do
      raise ArgumentError, "Standard reply parameters leave no room for a description"
    end

    %{message | trailing: truncate_utf8(description, available)}
  end

  def fit_message(message), do: message

  @spec type_command(:fail | :warn | :note) :: String.t()
  defp type_command(:fail), do: "FAIL"
  defp type_command(:warn), do: "WARN"
  defp type_command(:note), do: "NOTE"

  @spec validate_params!([String.t()]) :: :ok
  defp validate_params!([command, code | context]) do
    unless Regex.match?(~r/\A(?:[a-zA-Z]+|\*)\z/, command) and valid_context?(code) do
      raise ArgumentError, "Invalid standard reply command or code"
    end

    unless length(context) <= 12 and Enum.all?(context, &valid_context?/1) do
      raise ArgumentError, "Standard reply context must contain at most 12 valid IRC middle parameters"
    end

    :ok
  end

  defp validate_params!(_params), do: raise(ArgumentError, "Standard reply requires a command and code")

  @spec validate_description!(String.t() | nil) :: :ok
  defp validate_description!(description) do
    unless is_binary(description) and description != "" and String.valid?(description) and
             not String.contains?(description, ["\r", "\n", <<0>>]) do
      raise ArgumentError, "Standard reply description must be nonempty UTF-8 text without CR, LF or NUL"
    end

    :ok
  end

  @spec valid_context?(String.t()) :: boolean()
  defp valid_context?(value) do
    value != "" and String.valid?(value) and not String.starts_with?(value, ":") and
      not String.contains?(value, [" ", "\r", "\n", <<0>>])
  end

  @spec truncate_utf8(String.t(), non_neg_integer()) :: String.t()
  defp truncate_utf8(text, limit) when byte_size(text) <= limit, do: text

  defp truncate_utf8(text, limit) do
    truncated = binary_part(text, 0, limit)
    if String.valid?(truncated), do: truncated, else: truncate_utf8(text, limit - 1)
  end
end
