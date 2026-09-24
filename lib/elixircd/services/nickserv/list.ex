defmodule ElixIRCd.Services.Nickserv.List do
  @moduledoc "NickServ LIST command with account privacy filtering."

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv,
    only: [account_display_name: 1, belongs_to_account?: 2, get_account_nick: 1, notify: 2]

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1, match_glob?: 2]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["LIST"]), do: list_nicks(user, "*")
  def handle(user, ["LIST", pattern]), do: list_nicks(user, pattern)

  def handle(user, ["LIST" | _]) do
    notify(user, [
      "Too many parameters for \x02LIST\x02.",
      "Syntax: \x02LIST [pattern]\x02"
    ])
  end

  @spec list_nicks(User.t(), String.t()) :: :ok
  defp list_nicks(user, pattern) do
    nickserv = Application.fetch_env!(:elixircd, :services)[:nickserv]

    if not String.valid?(pattern) or String.length(pattern) > nickserv[:max_list_pattern_length] do
      notify(user, "LIST pattern is too long or contains invalid text.")
    else
      nicks =
        candidates(pattern)
        |> Enum.sort_by(&CaseMapping.normalize(&1.nickname))
        |> Enum.reduce_while([], fn registered_nick, matches ->
          collect_match(matches, registered_nick, user, pattern, nickserv[:max_list_results])
        end)
        |> Enum.reverse()

      notify_list_result(user, nicks)
    end
  end

  @spec candidates(String.t()) :: [RegisteredNick.t()]
  defp candidates(pattern) do
    if String.contains?(pattern, ["*", "?"]) do
      RegisteredNicks.get_all()
    else
      case RegisteredNicks.get_by_nickname(pattern) do
        {:ok, registered_nick} -> [registered_nick]
        {:error, :registered_nick_not_found} -> []
      end
    end
  end

  @spec collect_match([RegisteredNick.t()], RegisteredNick.t(), User.t(), String.t(), pos_integer()) ::
          {:cont, [RegisteredNick.t()]} | {:halt, [RegisteredNick.t()]}
  defp collect_match(matches, _registered_nick, _user, _pattern, max_results)
       when length(matches) >= max_results,
       do: {:halt, matches}

  defp collect_match(matches, registered_nick, user, pattern, _max_results) do
    if match_glob?(registered_nick.nickname, pattern) and visible_to?(user, registered_nick),
      do: {:cont, [registered_nick | matches]},
      else: {:cont, matches}
  end

  @spec notify_list_result(User.t(), [RegisteredNick.t()]) :: :ok
  defp notify_list_result(user, []) do
    notify(user, "No registered nicknames matched your search.")
  end

  defp notify_list_result(user, nicks) do
    notify(user, "Registered nicknames:")
    Enum.each(nicks, &notify_nick_entry(user, &1))
    notify(user, "End of list.")
  end

  @spec notify_nick_entry(User.t(), RegisteredNick.t()) :: :ok
  defp notify_nick_entry(user, registered_nick) do
    display_name = account_display_name(account_nick(registered_nick))

    if display_name == registered_nick.nickname do
      notify(user, "  #{registered_nick.nickname}")
    else
      notify(user, "  #{registered_nick.nickname} (#{display_name})")
    end
  end

  @spec visible_to?(User.t(), RegisteredNick.t()) :: boolean()
  defp visible_to?(user, registered_nick) do
    account = account_nick(registered_nick)
    private? = Map.get(account.settings, :private) == true

    not private? or irc_operator?(user) or belongs_to_account?(account, user.identified_as)
  end

  @spec account_nick(RegisteredNick.t()) :: RegisteredNick.t()
  defp account_nick(registered_nick) do
    case get_account_nick(registered_nick) do
      {:ok, account_nick} -> account_nick
      {:error, :registered_nick_not_found} -> registered_nick
    end
  end
end
