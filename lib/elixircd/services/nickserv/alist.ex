defmodule ElixIRCd.Services.Nickserv.Alist do
  @moduledoc """
  This module defines the NickServ ALIST command.

  ALIST displays all accounts that the user is recognized for based on
  their current authentication status and ACCESS list matches.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [grouped?: 1, notify: 2]
  import ElixIRCd.Utils.Protocol, only: [match_user_mask?: 2]

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["ALIST"]) do
    accounts = collect_recognized_accounts(user)

    if Enum.empty?(accounts) do
      notify(user, "You are not recognized for any accounts.")
    else
      display_accounts(user, accounts)
    end
  end

  @spec collect_recognized_accounts(User.t()) :: [{String.t(), atom()}]
  defp collect_recognized_accounts(user) do
    authenticated_accounts = collect_authenticated_account(user)
    access_accounts = collect_access_matched_accounts(user)

    # Combine and remove duplicates, keeping the first source for each account
    (authenticated_accounts ++ access_accounts)
    |> Enum.uniq_by(fn {nickname, _source} -> String.downcase(nickname) end)
    |> Enum.sort_by(fn {nickname, _source} -> String.downcase(nickname) end)
  end

  @spec collect_authenticated_account(User.t()) :: [{String.t(), atom()}]
  defp collect_authenticated_account(user) do
    case user.identified_as do
      nil ->
        []

      account ->
        source = if user.sasl_authenticated, do: :sasl, else: :authenticated
        [{account, source}]
    end
  end

  @spec collect_access_matched_accounts(User.t()) :: [{String.t(), atom()}]
  defp collect_access_matched_accounts(%{registered: false}), do: []

  defp collect_access_matched_accounts(user) do
    RegisteredNicks.get_all()
    |> Enum.reject(&grouped?/1)
    |> Enum.filter(&account_matches_access?(user, &1.account_name))
    |> Enum.map(&{&1.account_name, :access})
  end

  @spec account_matches_access?(User.t(), String.t()) :: boolean()
  defp account_matches_access?(user, account_name) do
    NickAccesses.get_by_account_name(account_name)
    |> Enum.any?(fn access_entry ->
      # Convert ACCESS mask (ident@host) to full mask (nick!ident@host)
      full_mask = "*!#{access_entry.mask}"
      match_user_mask?(user, full_mask)
    end)
  end

  @spec display_accounts(User.t(), [{String.t(), atom()}]) :: :ok
  defp display_accounts(user, accounts) do
    notify(user, "Accounts you are recognized for:")

    Enum.each(accounts, fn {nickname, source} ->
      notify(user, "  #{nickname} #{format_source(source)}")
    end)

    notify(user, "End of list.")
  end

  @spec format_source(atom()) :: String.t()
  defp format_source(:authenticated), do: "(authenticated)"
  defp format_source(:sasl), do: "(via SASL)"
  defp format_source(:access), do: "(via access)"
end
