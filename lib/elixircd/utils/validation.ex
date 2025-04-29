defmodule ElixIRCd.Utils.Validation do
  @moduledoc """
  Provides validation utilities for various data formats.
  """

  @email_regex ~r"^(?=.{1,254}$)(?=.{1,64}@)(?!\.)(?!.*\.\.)(?!.*\.$)[a-zA-Z0-9#$&'*+/=?^_`{|}~\-]+(?:\.[a-zA-Z0-9#$&'*+/=?^_`{|}~\-]+)*@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.[a-zA-Z]{2,}$"

  @doc """
  Validates an email address.
  """
  @spec validate_email(term()) :: :ok | {:error, :invalid_email}
  def validate_email(email) when is_binary(email) do
    if Regex.match?(@email_regex, email), do: :ok, else: {:error, :invalid_email}
  end

  def validate_email(_email), do: {:error, :invalid_email}
end
