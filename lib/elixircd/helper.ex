defmodule ElixIRCd.Helper do
  @moduledoc """
  Module for helper functions used throughout the IRC server.
  """

  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @doc """
  Determines if a target is a channel name.
  """
  @spec channel_name?(String.t()) :: boolean()
  def channel_name?(target), do: String.starts_with?(target, "#")

  @doc """
  Checks if a user is an IRC operator.
  """
  @spec irc_operator?(User.t()) :: boolean()
  def irc_operator?(user), do: "o" in user.modes

  @doc """
  Checks if a user is a channel operator.
  """
  @spec channel_operator?(UserChannel.t()) :: boolean()
  def channel_operator?(user_channel), do: "o" in user_channel.modes

  @doc """
  Checks if a user is a channel voice.
  """
  @spec channel_voice?(UserChannel.t()) :: boolean()
  def channel_voice?(user_channel), do: "v" in user_channel.modes

  @doc """
  Determines if a user mask matches a user.
  """
  @spec user_mask_match?(User.t(), String.t()) :: boolean()
  def user_mask_match?(user, mask) do
    mask
    |> String.replace(".", "\\.")
    |> String.replace("@", "\\@")
    |> String.replace("!", "\\!")
    |> String.replace("*", ".*")
    |> Regex.compile!()
    |> Regex.match?(get_user_mask(user))
  end

  @doc """
  Gets the user's reply to a message.
  """
  @spec get_user_reply(User.t()) :: String.t()
  def get_user_reply(%{registered: false}), do: "*"
  def get_user_reply(%{nick: nick}), do: nick

  @doc """
  Gets a list of targets from a comma-separated string.
  """
  @spec get_target_list(String.t()) :: {:channels, [String.t()]} | {:users, [String.t()]} | {:error, String.t()}
  def get_target_list(targets) do
    list_targets =
      targets
      |> String.split(",")

    cond do
      Enum.all?(list_targets, &channel_name?/1) ->
        {:channels, list_targets}

      Enum.all?(list_targets, fn target -> !channel_name?(target) end) ->
        {:users, list_targets}

      true ->
        {:error, "Invalid list of targets"}
    end
  end

  @doc """
  Gets the IP address for a socket connection.
  """
  @spec get_socket_ip(socket :: :inet.socket()) :: {:ok, :inet.ip_address()} | {:error, String.t()}
  def get_socket_ip(socket) do
    case :inet.peername(get_socket_port(socket)) do
      {:ok, {ip, _port}} -> {:ok, ip}
      {:error, error} -> {:error, "Unable to get IP for #{inspect(socket)}: #{inspect(error)}"}
    end
  end

  @doc """
  Gets the port that a socket is connected to.
  """
  @spec get_socket_port_connected(:inet.socket()) :: {:ok, :inet.port_number()} | {:error, String.t()}
  def get_socket_port_connected(socket) do
    case :inet.sockname(get_socket_port(socket)) do
      {:ok, {_, port}} -> {:ok, port}
      {:error, error} -> {:error, "Unable to get port for #{inspect(socket)}: #{inspect(error)}"}
    end
  end

  @doc """
  Gets the port for a socket.
  """
  @spec get_socket_port(:inet.socket()) :: port()
  def get_socket_port(socket) when is_port(socket), do: socket
  def get_socket_port({:sslsocket, {:gen_tcp, socket, :tls_connection, _}, _}), do: socket

  @doc """
  Gets the user mask.
  """
  @spec get_user_mask(User.t()) :: String.t()
  def get_user_mask(%{registered: true} = user)
      when user.nick != nil and user.ident != nil and user.hostname != nil do
    "#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname}"
  end

  def get_user_mask(%{registered: false}), do: "*"

  @doc """
  Lookups the hostname for an IP address.
  """
  @spec lookup_hostname(ip_address :: :inet.ip_address()) :: {:ok, String.t()} | {:error, String.t()}
  def lookup_hostname(ip_address) do
    case :inet.gethostbyaddr(ip_address) do
      {:ok, {:hostent, hostname, _, _, _, _}} -> {:ok, to_string(hostname)}
      {:error, error} -> {:error, "Unable to get hostname for #{inspect(ip_address)}: #{inspect(error)}"}
    end
  end

  @doc """
  Formats an IP address.
  """
  @spec format_ip_address(ip_address :: :inet.ip_address()) :: String.t()
  def format_ip_address({a, b, c, d}) do
    [a, b, c, d]
    |> Enum.map_join(".", &Integer.to_string/1)
  end

  def format_ip_address({a, b, c, d, e, f, g, h}) do
    formatted_ip =
      [a, b, c, d, e, f, g, h]
      |> Enum.map_join(":", &Integer.to_string(&1, 16))

    Regex.replace(~r/\b:?(?:0+:?){2,}/, formatted_ip, "::", global: false)
  end

  @doc """
  Formats a transport for display.
  """
  @spec format_transport(atom()) :: String.t()
  def format_transport(transport) when transport in [:ranch_tcp, :tcp], do: "TCP"
  def format_transport(transport) when transport in [:ranch_ssl, :ssl], do: "SSL"
  def format_transport(:ws), do: "WS"
  def format_transport(:wss), do: "WSS"

  @doc """
  Normalizes a mask to the *!*@* IRC format.
  """
  @spec normalize_mask(String.t()) :: String.t()
  def normalize_mask(mask) do
    {nick_user, host} =
      case String.split(mask, "@", parts: 2) do
        [nick_user, host] -> {nick_user, host}
        [nick_user] -> {nick_user, "*"}
      end

    {nick, user} =
      case String.split(nick_user, "!", parts: 2) do
        [nick, user] ->
          {nick, user}

        [nick_or_user] ->
          if String.contains?(mask, "@") do
            {"*", nick_or_user}
          else
            {nick_or_user, "*"}
          end
      end

    "#{empty_mask_part_to_wildcard(nick)}!#{empty_mask_part_to_wildcard(user)}@#{empty_mask_part_to_wildcard(host)}"
  end

  @spec empty_mask_part_to_wildcard(String.t()) :: String.t()
  defp empty_mask_part_to_wildcard(""), do: "*"
  defp empty_mask_part_to_wildcard(mask), do: mask
end
