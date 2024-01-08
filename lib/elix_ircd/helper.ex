defmodule ElixIRCd.Helper do
  @moduledoc """
  Module for helper functions.
  """

  alias ElixIRCd.Data.Schemas

  @doc """
  Extracts the targets from a comma-separated list of targets.

  ## Examples

      iex> ElixIRCd.MessageHelpers.extract_targets("#elixir,#elixircd")
      {:channels, ["#elixir", "#elixircd"]}

      iex> ElixIRCd.MessageHelpers.extract_targets("elixir,elixircd")
      {:users, ["elixir", "elixircd"]}

      iex> ElixIRCd.MessageHelpers.extract_targets("elixir,#elixircd")
      {:error, "Invalid targets"}
  """
  @spec extract_targets(String.t()) :: {:channels, [String.t()]} | {:users, [String.t()]} | {:error, String.t()}
  def extract_targets(targets) do
    list_targets =
      targets
      |> String.split(",")

    cond do
      Enum.all?(list_targets, &is_channel_name?/1) ->
        {:channels, list_targets}

      Enum.all?(list_targets, fn target -> !is_channel_name?(target) end) ->
        {:users, list_targets}

      true ->
        {:error, "Invalid list of targets"}
    end
  end

  @doc """
  Determines if a target is a channel name.
  """
  @spec is_channel_name?(String.t()) :: boolean()
  def is_channel_name?(target) do
    String.starts_with?(target, "#") ||
      String.starts_with?(target, "&") ||
      String.starts_with?(target, "+") ||
      String.starts_with?(target, "!")
  end

  @doc """
  Extracts the port from a socket.
  """
  @spec extract_port_socket(:inet.socket()) :: port()
  def extract_port_socket(socket) when is_port(socket), do: socket
  def extract_port_socket({:sslsocket, {:gen_tcp, socket, :tls_connection, _}, _}), do: socket

  @doc """
  Gets the reply for a user's identity.

  If the user has not registered, the reply is "*".
  Otherwise, the reply is the user's nick.
  """
  @spec get_user_reply(Schemas.User.t()) :: String.t()
  def get_user_reply(%{identity: nil}), do: "*"
  def get_user_reply(%{nick: nick}), do: nick
end
