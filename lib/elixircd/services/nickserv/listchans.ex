defmodule ElixIRCd.Services.Nickserv.Listchans do
  @moduledoc """
  This module defines the NickServ LISTCHANS command.

  LISTCHANS lists registered channels where the authenticated account is founder or successor.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, ["LISTCHANS" | _]) do
    notify(user, [
      "You must identify to NickServ before using the LISTCHANS command.",
      "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify."
    ])
  end

  def handle(user, ["LISTCHANS"]) do
    founder_channels =
      RegisteredChannels.get_by_founder(user.identified_as)
      |> Enum.map(&{&1.name, :founder})

    successor_channels =
      RegisteredChannels.get_by_successor(user.identified_as)
      |> Enum.map(&{&1.name, :successor})

    channels =
      (founder_channels ++ successor_channels)
      |> Enum.uniq_by(fn {channel_name, _role} -> String.downcase(channel_name) end)
      |> Enum.sort_by(fn {channel_name, _role} -> String.downcase(channel_name) end)

    if Enum.empty?(channels) do
      notify(user, "Your account is neither founder nor successor for any registered channel.")
    else
      notify(user, "Registered channels for \x02#{user.identified_as}\x02:")

      Enum.each(channels, fn {channel_name, role} ->
        notify(user, "  #{channel_name} #{format_role(role)}")
      end)

      notify(user, "End of list.")
    end
  end

  def handle(user, ["LISTCHANS" | _]) do
    notify(user, [
      "Too many parameters for \x02LISTCHANS\x02.",
      "Syntax: \x02LISTCHANS\x02"
    ])
  end

  @spec format_role(atom()) :: String.t()
  defp format_role(:founder), do: "(founder)"
  defp format_role(:successor), do: "(successor)"
end
