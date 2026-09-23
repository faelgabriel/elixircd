defmodule ElixIRCd.Utils.Targets do
  @moduledoc """
  Shared target limits for commands that accept comma-separated targets.

  These limits are part of the public IRC contract through the ISUPPORT
  `TARGMAX` token, so command handlers and advertisement use the same source.
  """

  @limits %{
    "KICK" => 4,
    "LIST" => 1,
    "NAMES" => 20,
    "NOTICE" => 4,
    "PRIVMSG" => 4,
    "TAGMSG" => 4,
    "WHOIS" => 1
  }

  @doc "Returns the advertised maximum target count for a command."
  @spec limit(String.t()) :: pos_integer()
  def limit(command), do: Map.fetch!(@limits, command)

  @doc "Splits a comma-separated target list and applies the command limit."
  @spec split(String.t(), String.t()) :: [String.t()]
  def split(command, targets) do
    targets
    |> String.split(",", trim: true)
    |> Enum.take(limit(command))
  end

  @doc "Formats the static portion of the ISUPPORT TARGMAX value."
  @spec targmax_value(non_neg_integer()) :: String.t()
  def targmax_value(monitor_limit) do
    [
      "NAMES:#{limit("NAMES")}",
      "LIST:#{limit("LIST")}",
      "KICK:#{limit("KICK")}",
      "WHOIS:#{limit("WHOIS")}",
      "PRIVMSG:#{limit("PRIVMSG")}",
      "NOTICE:#{limit("NOTICE")}",
      "TAGMSG:#{limit("TAGMSG")}",
      "MONITOR:#{monitor_limit}"
    ]
    |> Enum.join(",")
  end
end
