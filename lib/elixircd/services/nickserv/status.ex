defmodule ElixIRCd.Services.Nickserv.Status do
  @moduledoc """
  This module defines the NickServ STATUS command.

  STATUS returns the authentication/authority level a specific nickname has
  in relation to a registered account from NickServ's perspective.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [belongs_to_account?: 2, notify: 2]
  import ElixIRCd.Utils.Protocol, only: [match_user_mask?: 2]

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, arguments), do: handle_with_online_lookup(user, arguments, &Users.get_by_nick/1)

  @doc "Runs STATUS with an injected authoritative online-user lookup."
  @spec handle_with_online_lookup(User.t(), [String.t()], (String.t() -> {:ok, User.t()} | {:error, term()})) :: :ok
  def handle_with_online_lookup(user, ["STATUS" | nicks], online_lookup)
      when nicks != [] and is_function(online_lookup, 1) do
    Enum.each(nicks, fn nick ->
      status_code = calculate_status_for_nick(nick, online_lookup)
      notify(user, "STATUS #{nick} #{status_code}")
    end)

    :ok
  end

  def handle_with_online_lookup(user, ["STATUS"], _online_lookup) do
    notify(user, [
      "Insufficient parameters for \x02STATUS\x02.",
      "Syntax: \x02STATUS <nickname> [nickname2 ...]\x02"
    ])

    :ok
  end

  @spec calculate_status_for_nick(String.t(), (String.t() -> {:ok, User.t()} | {:error, term()})) :: 0 | 1 | 2 | 3
  defp calculate_status_for_nick(target_nick, online_lookup) do
    case RegisteredNicks.get_by_nickname(target_nick) do
      {:error, :registered_nick_not_found} ->
        # STATUS 0: Nick not registered
        0

      {:ok, registered_nick} ->
        calculate_status_for_registered(registered_nick, online_lookup)
    end
  end

  @spec calculate_status_for_registered(struct(), (String.t() -> {:ok, User.t()} | {:error, term()})) :: 1 | 2 | 3
  defp calculate_status_for_registered(registered_nick, online_lookup) do
    case online_lookup.(registered_nick.nickname) do
      {:error, :user_not_found} ->
        # STATUS 1: Registered but not online
        1

      {:ok, online_user} ->
        calculate_status_for_online(online_user, registered_nick)
    end
  end

  @spec calculate_status_for_online(User.t(), struct()) :: 1 | 2 | 3
  defp calculate_status_for_online(online_user, registered_nick) do
    cond do
      # Not identified to this nick
      !belongs_to_account?(registered_nick, online_user.identified_as) ->
        # STATUS 1: Registered but not authenticated
        1

      # Identified via SASL (trusted authentication)
      online_user.sasl_authenticated ->
        # STATUS 3: Authenticated and trusted (SASL)
        3

      # Check if user matches ACCESS list
      user_matches_access?(online_user, registered_nick.account_name) ->
        # STATUS 3: Authenticated and trusted (ACCESS match)
        3

      # Identified but no trust indicators
      true ->
        # STATUS 2: Authenticated but not trusted
        2
    end
  end

  @spec user_matches_access?(User.t(), String.t()) :: boolean()
  defp user_matches_access?(user, account_name) do
    NickAccesses.get_by_account_name(account_name)
    |> Enum.any?(fn access_entry ->
      full_mask = "*!#{access_entry.mask}"
      match_user_mask?(user, full_mask)
    end)
  end
end
