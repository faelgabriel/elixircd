defmodule ElixIRCd.Utils.Time do
  @moduledoc """
  Utility functions for handling dates and times.
  """

  @doc """
  Formats a DateTime into a human-readable date and time string.
  """
  @spec format_time(DateTime.t()) :: String.t()
  def format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  def format_time(nil), do: "(unknown)"
end
