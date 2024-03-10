defmodule ElixIRCd.Helper do
  @moduledoc """
  Module for helper functions.
  """

  alias ElixIRCd.Tables.User

  @doc """
  Determines if a target is a channel name.
  """
  @spec channel_name?(String.t()) :: boolean()
  def channel_name?(target) do
    String.starts_with?(target, "#") ||
      String.starts_with?(target, "&") ||
      String.starts_with?(target, "+") ||
      String.starts_with?(target, "!")
  end

  @doc """
  Checks if a socket is connected.
  """
  @spec socket_connected?(socket :: :inet.socket()) :: boolean()
  def socket_connected?(socket) do
    case :inet.peername(get_socket_port(socket)) do
      {:ok, _peer} -> true
      {:error, _} -> false
    end
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
  Gets the hostname for an IP address.
  """
  @spec get_socket_hostname(ip :: tuple()) :: {:ok, String.t()} | {:error, String.t()}
  def get_socket_hostname(ip) do
    case :inet.gethostbyaddr(ip) do
      {:ok, {:hostent, hostname, _, _, _, _}} -> {:ok, to_string(hostname)}
      {:error, error} -> {:error, "Unable to get hostname for #{inspect(ip)}: #{inspect(error)}"}
    end
  end

  @doc """
  Gets the IP address for a socket.
  """
  @spec get_socket_ip(socket :: :inet.socket()) :: {:ok, tuple()} | {:error, String.t()}
  def get_socket_ip(socket) do
    case :inet.peername(get_socket_port(socket)) do
      {:ok, {ip, _port}} -> {:ok, ip}
      {:error, error} -> {:error, "Unable to get IP for #{inspect(socket)}: #{inspect(error)}"}
    end
  end

  @doc """
  Gets the port for a socket.
  """
  @spec get_socket_port(:inet.socket()) :: port()
  def get_socket_port(socket) when is_port(socket), do: socket
  def get_socket_port({:sslsocket, {:gen_tcp, socket, :tls_connection, _}, _}), do: socket

  @doc """
  Builds the user mask.
  """
  @spec build_user_mask(User.t()) :: String.t()
  def build_user_mask(%{registered: true} = user)
      when user.nick != nil and user.username != nil and user.hostname != nil do
    "#{user.nick}!~#{String.slice(user.username, 0..8)}@#{user.hostname}"
  end

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
    |> Regex.match?(build_user_mask(user))
  end

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
