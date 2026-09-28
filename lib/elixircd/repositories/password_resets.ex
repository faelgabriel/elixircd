defmodule ElixIRCd.Repositories.PasswordResets do
  @moduledoc "Repository for NickServ password reset challenges."

  alias ElixIRCd.Tables.PasswordReset
  alias ElixIRCd.Utils.CaseMapping

  @doc "Reads an account's current reset challenge."
  @spec get(String.t(), keyword()) :: PasswordReset.t() | nil
  def get(account_name, opts \\ []) do
    Memento.Query.read(PasswordReset, CaseMapping.normalize(account_name), opts)
  end

  @doc "Stores a reset challenge."
  @spec put(PasswordReset.t()) :: PasswordReset.t()
  def put(reset), do: Memento.Query.write(reset)

  @doc "Deletes an account's reset challenge."
  @spec delete(String.t()) :: :ok
  def delete(account_name), do: Memento.Query.delete(PasswordReset, CaseMapping.normalize(account_name))

  @doc "Deletes expired reset challenges and returns their count."
  @spec delete_expired(DateTime.t()) :: non_neg_integer()
  def delete_expired(now) do
    PasswordReset
    |> Memento.Query.all()
    |> Enum.count(fn reset ->
      if DateTime.compare(reset.expires_at, now) == :gt do
        false
      else
        Memento.Query.delete_record(reset)
        true
      end
    end)
  end
end
