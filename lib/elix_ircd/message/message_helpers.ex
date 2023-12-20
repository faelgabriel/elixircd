defmodule ElixIRCd.Message.MessageHelpers do
  @moduledoc """
  This module defines helper functions for working with IRC messages.
  """

  @doc """
  Extracts the targets from a comma-separated list of targets.

  ## Examples

      iex> ElixIRCd.Message.MessageHelpers.extract_targets("#elixir,#elixircd")
      {:channels, ["#elixir", "#elixircd"]}

      iex> ElixIRCd.Message.MessageHelpers.extract_targets("elixir,elixircd")
      {:users, ["elixir", "elixircd"]}

      iex> ElixIRCd.Message.MessageHelpers.extract_targets("elixir,#elixircd")
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
end
