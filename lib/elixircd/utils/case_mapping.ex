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
    case_mapping = Application.get_env(:elixircd, :settings)[:case_mapping] || :rfc1459

    case case_mapping do
      :rfc1459 -> normalize(string, :rfc1459)
      :strict_rfc1459 -> normalize(string, :strict_rfc1459)
      :ascii -> normalize(string, :ascii)
    end
  end

  @spec normalize(String.t(), case_mapping()) :: String.t()
  defp normalize(string, :ascii) do
    String.downcase(string)
  end

  defp normalize(string, :rfc1459) do
    string
    |> String.downcase()
    |> String.replace(["{", "}", "|", "~"], fn
      "{" -> "["
      "}" -> "]"
      "|" -> "\\"
      "~" -> "^"
    end)
  end

  defp normalize(string, :strict_rfc1459) do
    string
    |> String.downcase()
    |> String.replace(["{", "}", "|"], fn
      "{" -> "["
      "}" -> "]"
      "|" -> "\\"
    end)
  end
end
