defmodule ElixIRCd.Services.Nickserv.Access do
  @moduledoc """
  This module defines the NickServ ACCESS command.

  ACCESS allows users to manage a list of authorized host masks for their registered nickname.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["ACCESS", subcommand | rest_params]) do
    if user.identified_as do
      normalized_subcommand = String.upcase(subcommand)

      case normalized_subcommand do
        "ADD" -> handle_add(user, rest_params)
        "DEL" -> handle_del(user, rest_params)
        "LIST" -> handle_list(user, rest_params)
        "CLEAR" -> handle_clear(user, rest_params)
        _ -> unknown_subcommand_message(user, subcommand)
      end
    else
      notify(user, [
        "You must identify to NickServ before using the ACCESS command.",
        "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify."
      ])
    end
  end

  def handle(user, ["ACCESS"]) do
    notify(user, [
      "Insufficient parameters for \x02ACCESS\x02.",
      "Syntax: \x02ACCESS {ADD|DEL|LIST|CLEAR} [mask]\x02"
    ])

    send_available_subcommands(user)
  end

  @spec handle_add(User.t(), [String.t()]) :: :ok
  defp handle_add(user, [mask | _rest_params]) do
    cond do
      not valid_mask_format?(mask) ->
        notify(user, [
          "Invalid mask format. The mask must contain \x02@\x02 and follow the format \x02[ident]@host\x02.",
          "Examples: \x02*@trusted.vpn\x02, \x02user@192.168.1.1\x02, \x02~user@*.example.com\x02"
        ])

      too_permissive_mask?(mask) ->
        notify(user, [
          "The mask \x02#{mask}\x02 is too permissive and poses a security risk.",
          "Please use a more specific mask. Avoid using \x02*@*\x02 or similar overly broad patterns."
        ])

      mask_exists?(user.identified_as, mask) ->
        notify(user, "The mask \x02#{mask}\x02 is already in your access list.")

      max_entries_reached?(user.identified_as) ->
        max_entries = get_max_access_entries()

        notify(user, [
          "Your access list is full. You can have a maximum of \x02#{max_entries}\x02 entries.",
          "Use \x02/msg NickServ ACCESS DEL <mask>\x02 to remove an entry first."
        ])

      true ->
        add_access_entry(user, mask)
    end
  end

  defp handle_add(user, []) do
    notify(user, [
      "Insufficient parameters for \x02ACCESS ADD\x02.",
      "Syntax: \x02ACCESS ADD <mask>\x02",
      "",
      "Example: \x02/msg NickServ ACCESS ADD *@trusted.vpn\x02"
    ])
  end

  @spec handle_del(User.t(), [String.t()]) :: :ok
  defp handle_del(user, [mask | _rest_params]) do
    if mask_exists?(user.identified_as, mask) do
      delete_access_entry(user, mask)
    else
      notify(user, "The mask \x02#{mask}\x02 is not in your access list.")
    end
  end

  defp handle_del(user, []) do
    notify(user, [
      "Insufficient parameters for \x02ACCESS DEL\x02.",
      "Syntax: \x02ACCESS DEL <mask>\x02",
      "",
      "Example: \x02/msg NickServ ACCESS DEL *@trusted.vpn\x02"
    ])
  end

  @spec handle_list(User.t(), [String.t()]) :: :ok
  defp handle_list(user, _rest_params) do
    entries = NickAccesses.get_by_nickname(user.identified_as)

    if Enum.empty?(entries) do
      notify(user, "Your access list is empty.")
    else
      notify(user, "Access list for \x02#{user.identified_as}\x02:")

      entries
      |> Enum.with_index(1)
      |> Enum.each(fn {entry, index} ->
        formatted_date = format_datetime(entry.created_at)
        notify(user, "#{index}. \x02#{entry.mask}\x02 (added: #{formatted_date})")
      end)

      notify(user, "End of access list.")
    end
  end

  @spec handle_clear(User.t(), [String.t()]) :: :ok
  defp handle_clear(user, _rest_params) do
    count = NickAccesses.count_by_nickname(user.identified_as)

    if count == 0 do
      notify(user, "Your access list is already empty.")
    else
      NickAccesses.delete_by_nickname(user.identified_as)

      notify(user, [
        "Your access list has been cleared.",
        "Removed \x02#{count}\x02 #{pluralize_entries(count)} from your access list."
      ])
    end
  end

  @spec add_access_entry(User.t(), String.t()) :: :ok
  defp add_access_entry(user, mask) do
    NickAccesses.create(%{
      nickname_key: CaseMapping.normalize(user.identified_as),
      mask: mask
    })

    notify(user, "Added \x02#{mask}\x02 to your access list.")
  end

  @spec delete_access_entry(User.t(), String.t()) :: :ok
  defp delete_access_entry(user, mask) do
    NickAccesses.delete(user.identified_as, mask)
    notify(user, "Removed \x02#{mask}\x02 from your access list.")
  end

  @spec valid_mask_format?(String.t()) :: boolean()
  defp valid_mask_format?(mask) do
    String.contains?(mask, "@") && String.length(mask) > 1
  end

  @spec too_permissive_mask?(String.t()) :: boolean()
  defp too_permissive_mask?(mask) do
    normalized_mask = String.downcase(mask)
    normalized_mask == "*@*" || normalized_mask == "@*"
  end

  @spec mask_exists?(String.t(), String.t()) :: boolean()
  defp mask_exists?(nickname, mask) do
    NickAccesses.get_by_nickname_and_mask(nickname, mask) != nil
  end

  @spec max_entries_reached?(String.t()) :: boolean()
  defp max_entries_reached?(nickname) do
    count = NickAccesses.count_by_nickname(nickname)
    max_entries = get_max_access_entries()
    count >= max_entries
  end

  @spec get_max_access_entries() :: integer()
  defp get_max_access_entries do
    Application.get_env(:elixircd, :services)[:nickserv][:max_access_entries] || 10
  end

  @spec format_datetime(DateTime.t()) :: String.t()
  defp format_datetime(datetime) do
    iso_str = DateTime.to_iso8601(datetime)
    String.replace(iso_str, "T", " ")
  end

  @spec pluralize_entries(integer()) :: String.t()
  defp pluralize_entries(1), do: "entry"
  defp pluralize_entries(_), do: "entries"

  @spec unknown_subcommand_message(User.t(), String.t()) :: :ok
  defp unknown_subcommand_message(user, subcommand) do
    notify(user, "Unknown ACCESS subcommand: \x02#{subcommand}\x02")
    send_available_subcommands(user)
  end

  @spec send_available_subcommands(User.t()) :: :ok
  defp send_available_subcommands(user) do
    notify(user, [
      "Available ACCESS subcommands:",
      "\x02ADD <mask>\x02    - Add a host mask to your access list",
      "\x02DEL <mask>\x02    - Remove a host mask from your access list",
      "\x02LIST\x02          - Display your access list",
      "\x02CLEAR\x02         - Remove all entries from your access list"
    ])
  end
end
