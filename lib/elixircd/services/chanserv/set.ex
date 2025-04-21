defmodule ElixIRCd.Services.Chanserv.Set do
  @moduledoc """
  Handles the ChanServ SET command, which allows founders to modify channel settings.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]
  import ElixIRCd.Utils.Validation, only: [validate_email: 1]

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User

  @command_name "SET"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name, setting | args]) do
    channel_name = String.downcase(channel_name)
    setting = String.upcase(setting)

    case check_channel_ownership(user, channel_name) do
      {:ok, channel} ->
        handle_setting(user, channel, setting, args)

      {:error, :channel_not_registered} ->
        notify(user, "Channel #{channel_name} is not registered.")

      {:error, :not_founder} ->
        notify(user, "Access denied. You are not the founder of #{channel_name}.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, [
      "Syntax: SET <channel> <option> [parameters]",
      "For help, type: /msg ChanServ HELP SET"
    ])
  end

  @spec check_channel_ownership(User.t(), String.t()) :: {:ok, Channel.t()} | {:error, atom()}
  defp check_channel_ownership(user, channel_name) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, channel} ->
        if channel.founder == user.identified_as do
          {:ok, channel}
        else
          {:error, :not_founder}
        end

      {:error, :registered_channel_not_found} ->
        {:error, :channel_not_registered}
    end
  end

  @spec handle_setting(User.t(), Channel.t(), String.t(), [String.t()]) :: :ok
  defp handle_setting(user, channel, "GUARD", args), do: handle_guard(user, channel, args)
  defp handle_setting(user, channel, "KEEPTOPIC", args), do: handle_keeptopic(user, channel, args)
  defp handle_setting(user, channel, "PRIVATE", args), do: handle_private(user, channel, args)
  defp handle_setting(user, channel, "RESTRICTED", args), do: handle_restricted(user, channel, args)
  defp handle_setting(user, channel, "FANTASY", args), do: handle_fantasy(user, channel, args)
  defp handle_setting(user, channel, "DESCRIPTION", args), do: handle_description(user, channel, args)
  defp handle_setting(user, channel, "DESC", args), do: handle_description(user, channel, args)
  defp handle_setting(user, channel, "URL", args), do: handle_url(user, channel, args)
  defp handle_setting(user, channel, "EMAIL", args), do: handle_email(user, channel, args)
  defp handle_setting(user, channel, "ENTRYMSG", args), do: handle_entrymsg(user, channel, args)
  defp handle_setting(user, channel, "OPNOTICE", args), do: handle_opnotice(user, channel, args)
  defp handle_setting(user, channel, "PEACE", args), do: handle_peace(user, channel, args)
  defp handle_setting(user, channel, "SECURE", args), do: handle_secure(user, channel, args)
  defp handle_setting(user, channel, "TOPICLOCK", args), do: handle_topiclock(user, channel, args)

  defp handle_setting(user, _channel, setting, _args) do
    notify(user, [
      "Unknown setting: \2#{setting}\2",
      "For a list of settings, type: /msg ChanServ HELP SET"
    ])
  end

  @spec handle_guard(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_guard(user, channel, ["ON"]) do
    update_setting(user, channel, :guard, true)
  end

  defp handle_guard(user, channel, ["OFF"]) do
    update_setting(user, channel, :guard, false)
  end

  defp handle_guard(user, _channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2GUARD\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_guard(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_keeptopic(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_keeptopic(user, channel, ["ON"]) do
    update_setting(user, channel, :keeptopic, true)
  end

  defp handle_keeptopic(user, channel, ["OFF"]) do
    update_setting(user, channel, :keeptopic, false)
  end

  defp handle_keeptopic(user, _channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2KEEPTOPIC\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_keeptopic(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_private(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_private(user, channel, ["ON"]) do
    update_setting(user, channel, :private, true)
  end

  defp handle_private(user, channel, ["OFF"]) do
    update_setting(user, channel, :private, false)
  end

  defp handle_private(user, _channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2PRIVATE\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_private(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_restricted(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_restricted(user, channel, ["ON"]) do
    update_setting(user, channel, :restricted, true)
  end

  defp handle_restricted(user, channel, ["OFF"]) do
    update_setting(user, channel, :restricted, false)
  end

  defp handle_restricted(user, _channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2RESTRICTED\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_restricted(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_fantasy(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_fantasy(user, channel, ["ON"]) do
    update_setting(user, channel, :fantasy, true)
  end

  defp handle_fantasy(user, channel, ["OFF"]) do
    update_setting(user, channel, :fantasy, false)
  end

  defp handle_fantasy(user, _channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2FANTASY\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_fantasy(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_description(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_description(user, channel, []) do
    if channel.settings.description do
      notify(user, "\2DESCRIPTION\2 for \2#{channel.name}\2 is: \2#{channel.settings.description}\2")
    else
      notify(user, "No \2DESCRIPTION\2 is set for \2#{channel.name}\2.")
    end
  end

  defp handle_description(user, channel, description) do
    description_text = Enum.join(description, " ")

    if String.trim(description_text) == "" do
      update_setting(user, channel, :description, nil)
    else
      update_setting(user, channel, :description, description_text)
    end
  end

  @spec handle_url(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_url(user, channel, []) do
    if channel.settings.url do
      notify(user, "\2URL\2 for \2#{channel.name}\2 is: \2#{channel.settings.url}\2")
    else
      notify(user, "No \2URL\2 is set for \2#{channel.name}\2.")
    end
  end

  defp handle_url(user, channel, ["OFF"]) do
    update_setting(user, channel, :url, nil)
  end

  defp handle_url(user, channel, [url]) do
    update_setting(user, channel, :url, url)
  end

  defp handle_url(user, _channel, _) do
    notify(user, "Syntax: SET <channel> URL <url> or SET <channel> URL OFF to clear")
  end

  @spec handle_email(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_email(user, channel, []) do
    if channel.settings.email do
      notify(user, "\2EMAIL\2 for \2#{channel.name}\2 is: \2#{channel.settings.email}\2")
    else
      notify(user, "No \2EMAIL\2 is set for \2#{channel.name}\2.")
    end
  end

  defp handle_email(user, channel, ["OFF"]) do
    update_setting(user, channel, :email, nil)
  end

  defp handle_email(user, channel, [email]) do
    sanitized_email = email |> String.trim() |> String.downcase()

    case validate_email(sanitized_email) do
      :ok -> update_setting(user, channel, :email, sanitized_email)
      {:error, :invalid_email} -> notify(user, "\2#{sanitized_email}\2 is not a valid email address.")
    end
  end

  defp handle_email(user, _channel, _) do
    notify(user, "Syntax: SET <channel> EMAIL <email> or SET <channel> EMAIL OFF to clear")
  end

  @spec handle_entrymsg(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_entrymsg(user, channel, []) do
    if channel.settings.entry_message do
      notify(user, "\2ENTRY_MESSAGE\2 for \2#{channel.name}\2 is: \2#{channel.settings.entry_message}\2")
    else
      notify(user, "No \2ENTRY_MESSAGE\2 is set for \2#{channel.name}\2.")
    end
  end

  defp handle_entrymsg(user, channel, ["OFF"]) do
    update_setting(user, channel, :entry_message, nil)
  end

  defp handle_entrymsg(user, channel, message) do
    message_text = Enum.join(message, " ")

    if String.trim(message_text) == "" do
      update_setting(user, channel, :entry_message, nil)
    else
      update_setting(user, channel, :entry_message, message_text)
    end
  end

  @spec handle_opnotice(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_opnotice(user, channel, ["ON"]) do
    update_setting(user, channel, :op_notice, true)
  end

  defp handle_opnotice(user, channel, ["OFF"]) do
    update_setting(user, channel, :op_notice, false)
  end

  defp handle_opnotice(user, _channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2OPNOTICE\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_opnotice(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_peace(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_peace(user, channel, ["ON"]) do
    update_setting(user, channel, :peace, true)
  end

  defp handle_peace(user, channel, ["OFF"]) do
    update_setting(user, channel, :peace, false)
  end

  defp handle_peace(user, _channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2PEACE\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_peace(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_secure(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_secure(user, channel, ["ON"]) do
    update_setting(user, channel, :secure, true)
  end

  defp handle_secure(user, channel, ["OFF"]) do
    update_setting(user, channel, :secure, false)
  end

  defp handle_secure(user, _channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2SECURE\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_secure(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_topiclock(User.t(), Channel.t(), [String.t()]) :: :ok
  defp handle_topiclock(user, channel, []) do
    case channel.settings.topiclock do
      true -> notify(user, "\2TOPICLOCK\2 for \2#{channel.name}\2 is set to: \2ON\2")
      false -> notify(user, "\2TOPICLOCK\2 for \2#{channel.name}\2 is set to: \2OFF\2")
    end
  end

  defp handle_topiclock(user, channel, ["ON"]) do
    update_setting(user, channel, :topiclock, true)
  end

  defp handle_topiclock(user, channel, ["OFF"]) do
    update_setting(user, channel, :topiclock, false)
  end

  defp handle_topiclock(user, _channel, [value]) do
    notify(
      user,
      "\2#{value}\2 is not a valid setting for \2TOPICLOCK\2. Use \2ON\2 or \2OFF\2."
    )
  end

  defp handle_topiclock(user, _channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec update_setting(User.t(), RegisteredChannel.t(), atom(), any()) :: :ok
  defp update_setting(user, channel, setting, value) do
    updated_settings = RegisteredChannel.Settings.update(channel.settings, %{setting => value})
    RegisteredChannels.update(channel, %{settings: updated_settings})

    setting_name = setting |> to_string() |> String.upcase()

    message =
      case value do
        true -> "\2#{setting_name}\2 option for \2#{channel.name}\2 is now \2ON\2"
        false -> "\2#{setting_name}\2 option for \2#{channel.name}\2 is now \2OFF\2"
        nil -> "\2#{setting_name}\2 for \2#{channel.name}\2 has been unset"
        _ -> "\2#{setting_name}\2 for \2#{channel.name}\2 has been set to: \2#{value}\2"
      end

    notify(user, message)
  end
end
