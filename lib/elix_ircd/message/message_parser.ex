defmodule ElixIRCd.Message.MessageParser do
  @moduledoc """
  Module for parsing raw IRC messages to IrcMessage structs and vice versa.
  """

  alias ElixIRCd.Message.Message

  @doc """
  Parses a raw IRC message string into an IrcMessage struct.

  ## Examples
  - For a message ":irc.example.com NOTICE user :Server restarting",
  - the function parses it into `%Message{source: "irc.example.com", command: "NOTICE", params: ["user"], body: "Server restarting"}`

  - For a message "JOIN #channel",
  - the function parses it into `%Message{source: nil, command: "JOIN", params: ["#channel"], body: nil}`

  - For a message ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user",
  - the function parses it into `%Message{source: "Freenode.net", command: "001", params: ["user"], body: "Welcome to the freenode Internet Relay Chat Network user"}`
  """
  @spec parse(String.t()) :: {:ok, Message.t()} | {:error, String.t()}
  def parse(message) do
    {source, message} = extract_source(message)

    parse_command_and_params(message)
    |> case do
      {command, params, body} -> {:ok, %Message{source: source, command: command, params: params, body: body}}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Parses the IrcMessage struct into a raw IRC message string.
  Raises an ArgumentError if the message cannot be unparsed.
  """
  def parse!(message) do
    case parse(message) do
      {:ok, parsed} -> parsed
      {:error, error} -> raise ArgumentError, error
    end
  end

  @doc """
  Unparses the IrcMessage struct into a raw IRC message string.

  ## Examples
  - For `%Message{source: "irc.example.com", command: "NOTICE", params: ["user"], body: "Server restarting"}`,
  - the function unparses it into ":irc.example.com NOTICE user :Server restarting"

  - For `%Message{source: nil, command: "JOIN", params: ["#channel"], body: nil}`,
  - the function unparses it into "JOIN #channel"

  - For `%Message{source: "Freenode.net", command: "001", params: ["user"], body: "Welcome to the freenode Internet Relay Chat Network user"}`,
  - the function unparses it into ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"
  """
  @spec unparse(Message.t()) :: {:ok, String.t()} | {:error, String.t()}
  def unparse(%Message{command: nil}), do: {:error, "Invalid IRC message format"}

  def unparse(%Message{source: nil, command: command, params: params, body: body}) do
    base = [command | params]
    {:ok, unparse_message(base, body)}
  end

  def unparse(%Message{source: source, command: command, params: params, body: body}) do
    base = [":" <> source, command | params]
    {:ok, unparse_message(base, body)}
  end

  @doc """
  Unparses the IrcMessage struct into a raw IRC message string.
  Raises an ArgumentError if the message cannot be unparsed.
  """
  @spec unparse!(Message.t()) :: String.t()
  def unparse!(message) do
    case unparse(message) do
      {:ok, unparsed} -> unparsed
      {:error, error} -> raise ArgumentError, error
    end
  end

  # Extracts the source from the message if present.
  # It returns {source, message_without_source}.
  @spec extract_source(String.t()) :: {String.t() | nil, String.t()}
  defp extract_source(":" <> message) do
    [source | rest] = String.split(message, " ", parts: 2)
    {String.trim_leading(source, ":"), Enum.join(rest, " ")}
  end

  defp extract_source(message), do: {nil, message}

  # Parses the command and parameters from the message.
  # It returns {command, params, body} or {:error, error}.
  @spec parse_command_and_params(String.t()) :: {String.t(), [String.t()], String.t() | nil} | {:error, String.t()}
  defp parse_command_and_params(message) do
    parts = String.split(message, " ", trim: true)

    case parts do
      [command | params_and_body] ->
        {params, body} = extract_body(params_and_body)
        {String.upcase(command), params, body}

      [] ->
        {:error, "Invalid IRC message format"}
    end
  end

  # Extracts the body from the parameters if present.
  # It returns {params, body} or {params, nil}.
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
