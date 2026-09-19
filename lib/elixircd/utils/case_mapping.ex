defmodule ElixIRCd.Utils.CaseMapping do
  @moduledoc """
  Module for utility functions related to the case mapping.
  """

  @type case_mapping :: :ascii | :rfc1459 | :strict_rfc1459

  @doc """
  Normalizes a string based on the case mapping configuration.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(string) do
    case_mapping = Application.fetch_env!(:elixircd, :settings)[:case_mapping]

    case case_mapping do
      :rfc1459 -> normalize(string, :rfc1459)
      :strict_rfc1459 -> normalize(string, :strict_rfc1459)
      :ascii -> normalize(string, :ascii)
    end
  end

  @spec normalize(String.t(), case_mapping()) :: String.t()
  defp normalize(string, :ascii) do
    ascii_lower(string)
  end

  defp normalize(string, :rfc1459) do
    string
    |> ascii_lower()
    |> String.replace(["{", "}", "|", "~"], fn
      "{" -> "["
      "}" -> "]"
      "|" -> "\\"
      "~" -> "^"
    end)
  end

  defp normalize(string, :strict_rfc1459) do
    string
    |> ascii_lower()
    |> String.replace(["{", "}", "|"], fn
      "{" -> "["
      "}" -> "]"
      "|" -> "\\"
    end)
  end

  # IRC casemappings operate on ASCII code points. UTF-8 bytes outside A-Z
  # must remain unchanged even when the configured mapping is `ascii`.
  @spec ascii_lower(binary()) :: binary()
  defp ascii_lower(value) do
    for <<byte <- value>>, into: <<>>, do: <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>
  end
end
