defmodule ElixIRCd.Parsers.IrcMessageParser do
  @moduledoc """
  Module for parsing IRC messages to IrcMessage structs.
  """

  alias ElixIRCd.Structs.IrcMessage

  @doc """
  Parses a raw IRC message string into an IrcMessage struct.

  ## Examples
  - For a message ":irc.example.com NOTICE user :Server restarting",
  - the function parses it into `%IrcMessage{prefix: "irc.example.com", command: "NOTICE", params: ["user"], body: "Server restarting"}`

  - For a message "JOIN #channel",
  - the function parses it into `%IrcMessage{prefix: nil, command: "JOIN", params: ["#channel"], body: nil}`

  - For a message ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user",
  - the function parses it into `%IrcMessage{prefix: "Freenode.net", command: "001", params: ["user"], body: "Welcome to the freenode Internet Relay Chat Network user"}`
  """
  @spec parse(String.t()) :: IrcMessage.t()
  def parse(message) do
    {prefix, message} = extract_prefix(message)
    {command, params, body} = parse_command_and_params(message)

    %IrcMessage{prefix: prefix, command: command, params: params, body: body}
  end

  @doc """
  Unparses the IrcMessage struct into a raw IRC message string.

  ## Examples
  - For `%IrcMessage{prefix: "irc.example.com", command: "NOTICE", params: ["user"], body: "Server restarting"}`,
  - the function unparses it into ":irc.example.com NOTICE user :Server restarting"

  - For `%IrcMessage{prefix: nil, command: "JOIN", params: ["#channel"], body: nil}`,
  - the function unparses it into "JOIN #channel"

  - For `%IrcMessage{prefix: "Freenode.net", command: "001", params: ["user"], body: "Welcome to the freenode Internet Relay Chat Network user"}`,
  - the function unparses it into ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"
  """
  @spec unparse(IrcMessage.t()) :: String.t()
  def unparse(%IrcMessage{prefix: nil, command: command, params: params, body: body}) do
    base = [command | params]
    unparse_message(base, body)
  end

  def unparse(%IrcMessage{prefix: prefix, command: command, params: params, body: body}) do
    base = [":" <> prefix, command | params]
    unparse_message(base, body)
  end

  # Extracts the prefix from the message if present.
  @spec extract_prefix(String.t()) :: {String.t() | nil, String.t()}
  defp extract_prefix(message) do
    case String.starts_with?(message, ":") do
      true ->
        parts = String.split(message, " ", parts: 2)

        case parts do
          [prefix | rest] ->
            {String.trim_leading(prefix, ":"), Enum.join(rest, " ")}

          # [prefix] -> will never match type because the prefix is always followed by a space

          _ ->
            {nil, message}
        end

      false ->
        {nil, message}
    end
  end

  # Parses the command and parameters from the message.
  @spec parse_command_and_params(String.t()) :: {String.t(), [String.t()], String.t() | nil}
  defp parse_command_and_params(message) do
    [command | params_and_body] = String.split(message, " ", trim: true)
    {params, body} = extract_body(params_and_body)

    {command, params, body}
  end

  # Extracts the body from the parameters if present.
  @spec extract_body([String.t()]) :: {[String.t()], String.t() | nil}
  defp extract_body(parts) do
    # Find the index of the part where the body begins (first part containing a ':')
    body_index = Enum.find_index(parts, &String.contains?(&1, ":"))

    case body_index do
      nil ->
        # No body part; all parts are parameters
        {parts, nil}

      index ->
        # Extract parameters and body
        params = Enum.take(parts, index)
        body_parts = Enum.drop(parts, index)
        body = body_parts |> Enum.join(" ") |> String.trim_leading(":")
        {params, body}
    end
  end

  # Joins the base and body parts into a single message.
  @spec unparse_message([String.t()], String.t() | nil) :: String.t()
  defp unparse_message(base, nil), do: Enum.join(base, " ")
  defp unparse_message(base, body), do: Enum.join(base ++ [":" <> body], " ")
end
