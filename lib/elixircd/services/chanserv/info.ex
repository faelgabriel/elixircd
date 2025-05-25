defmodule ElixIRCd.Services.Chanserv.Info do
  @moduledoc """
  Module for the ChanServ INFO command.
  This command provides information about registered channels.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]
  import ElixIRCd.Utils.Time, only: [format_time: 1]

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User

  @command_name "INFO"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, [@command_name]) do
    notify(user, [
      "Insufficient parameters for \x02INFO\x02.",
      "Syntax: \x02INFO <channel> [ALL]\x02"
    ])
  end

  def handle(user, [@command_name, channel_name | rest]) do
    show_all? = rest |> List.first() |> to_string() |> String.upcase() == "ALL"

    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, registered_channel} ->
        display_channel_info(user, registered_channel, show_all?)

      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")
    end
  end

  @spec display_channel_info(User.t(), RegisteredChannel.t(), boolean()) :: :ok
  defp display_channel_info(user, channel, show_all?) do
    founder? = channel.founder == user.identified_as
    privileged? = founder? || has_view_access?(user, channel)

    # Always show basic information
    notify(user, [
      "Information for channel \x02#{channel.name}\x02:",
      "Founder: #{channel.founder}",
      "Description: #{channel.settings.description || "(none)"}",
      "Registered: #{format_time(channel.created_at)}",
      "Last used: #{format_time(channel.last_used_at)}"
    ])

    # Show additional information for privileged users
    if privileged? || show_all? do
      display_privileged_info(user, channel)
    end

    # Show all settings details if founder and ALL parameter was used
    if founder? && show_all? do
      display_all_info(user, channel)
    end

    notify(user, "***** End of Info *****")
  end

  @spec display_privileged_info(User.t(), RegisteredChannel.t()) :: :ok
  defp display_privileged_info(user, channel) do
    flags = format_channel_flags(channel)

    additional_info = [
      "Flags: #{flags}",
      "Mode lock: #{channel.settings.mlock || "(none)"}",
      "Entry message: #{channel.settings.entrymsg || "(none)"}"
    ]

    if channel.topic do
      topic_info = [
        "Last topic: #{channel.topic.text}",
        "Topic set by: #{channel.topic.setter} (#{format_time(channel.topic.set_at)})"
      ]

      notify(user, additional_info ++ topic_info)
    else
      notify(user, additional_info ++ ["Last topic: (none)"])
    end
  end

  @spec display_all_info(User.t(), RegisteredChannel.t()) :: :ok
  defp display_all_info(user, channel) do
    # Calculate expiry time if applicable
    expiry_info = calculate_expiry_info(channel)

    all_info = [
      "URL: #{channel.settings.url || "(none)"}",
      "Email: #{channel.settings.email || "(none)"}",
      "Successor: #{channel.successor || "(none)"}",
      expiry_info
    ]

    notify(user, all_info)
  end

  @spec format_channel_flags(RegisteredChannel.t()) :: String.t()
  defp format_channel_flags(channel) do
    flag_map = %{
      "GUARD" => channel.settings.guard,
      "KEEPTOPIC" => channel.settings.keeptopic,
      "PRIVATE" => channel.settings.private,
      "RESTRICTED" => channel.settings.restricted,
      "FANTASY" => channel.settings.fantasy,
      "OPNOTICE" => channel.settings.opnotice,
      "PEACE" => channel.settings.peace,
      "SECURE" => channel.settings.secure,
      "TOPICLOCK" => channel.settings.topiclock
    }

    flags =
      flag_map
      |> Enum.filter(fn {_flag, enabled} -> enabled end)
      |> Enum.map(fn {flag, _enabled} -> flag end)

    case flags do
      [] -> "(none)"
      _ -> Enum.join(flags, ", ")
    end
  end

  @spec has_view_access?(User.t(), RegisteredChannel.t()) :: boolean()
  defp has_view_access?(user, channel) do
    # In a full implementation, check channel access list for +A or equivalent flags
    # For now, simplified to only allow founders to see privileged info
    channel.founder == user.identified_as
  end

  @spec calculate_expiry_info(RegisteredChannel.t()) :: String.t()
  defp calculate_expiry_info(channel) do
    channel_expire_days = Application.get_env(:elixircd, :services)[:chanserv][:channel_expire_days] || 60
    expire_at = DateTime.add(channel.last_used_at, channel_expire_days, :day)

    "Expires: #{format_time(expire_at)}"
  end
end
