defmodule ElixIRCd.Services.Chanserv.Set do
  @moduledoc """
  This module defines the ChanServ SET command.

  SET allows channel founders to modify channel settings and options.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]
  import ElixIRCd.Utils.Validation, only: [validate_email: 1]

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User

  @command_name "SET"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name, setting | args]) do
    setting = String.upcase(setting)

    case check_channel_ownership(user, channel_name) do
      {:ok, registered_channel} ->
        handle_setting(user, registered_channel, setting, args)

      {:error, :registered_channel_not_found} ->
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

  @spec check_channel_ownership(User.t(), String.t()) ::
          {:ok, RegisteredChannel.t()} | {:error, :not_founder | :registered_channel_not_found}
  defp check_channel_ownership(user, channel_name) do
    with {:ok, registered_channel} <- RegisteredChannels.get_by_name(channel_name) do
      if registered_channel.founder == user.identified_as do
        {:ok, registered_channel}
      else
        {:error, :not_founder}
      end
    end
  end

  @spec handle_setting(User.t(), RegisteredChannel.t(), String.t(), [String.t()]) :: :ok
  defp handle_setting(user, registered_channel, "GUARD", args), do: handle_guard(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "KEEPTOPIC", args), do: handle_keeptopic(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "PRIVATE", args), do: handle_private(user, registered_channel, args)

  defp handle_setting(user, registered_channel, "RESTRICTED", args),
    do: handle_restricted(user, registered_channel, args)

  defp handle_setting(user, registered_channel, "FANTASY", args), do: handle_fantasy(user, registered_channel, args)

  defp handle_setting(user, registered_channel, "DESCRIPTION", args),
    do: handle_description(user, registered_channel, args)

  defp handle_setting(user, registered_channel, "DESC", args), do: handle_description(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "URL", args), do: handle_url(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "EMAIL", args), do: handle_email(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "ENTRYMSG", args), do: handle_entrymsg(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "OPNOTICE", args), do: handle_opnotice(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "PEACE", args), do: handle_peace(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "SECURE", args), do: handle_secure(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "TOPICLOCK", args), do: handle_topiclock(user, registered_channel, args)
  defp handle_setting(user, registered_channel, "SUCCESSOR", args), do: handle_successor(user, registered_channel, args)

  defp handle_setting(user, _registered_channel, setting, _args) do
    notify(user, [
      "Unknown setting: \2#{setting}\2",
      "For a list of settings, type: /msg ChanServ HELP SET"
    ])
  end

  @spec handle_guard(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_guard(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :guard, true)
  end

  defp handle_guard(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :guard, false)
  end

  defp handle_guard(user, _registered_channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2GUARD\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_guard(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_keeptopic(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_keeptopic(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :keeptopic, true)
  end

  defp handle_keeptopic(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :keeptopic, false)
  end

  defp handle_keeptopic(user, _registered_channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2KEEPTOPIC\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_keeptopic(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_private(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_private(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :private, true)
  end

  defp handle_private(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :private, false)
  end

  defp handle_private(user, _registered_channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2PRIVATE\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_private(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_restricted(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_restricted(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :restricted, true)
  end

  defp handle_restricted(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :restricted, false)
  end

  defp handle_restricted(user, _registered_channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2RESTRICTED\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_restricted(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_fantasy(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_fantasy(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :fantasy, true)
  end

  defp handle_fantasy(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :fantasy, false)
  end

  defp handle_fantasy(user, _registered_channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2FANTASY\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_fantasy(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_description(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_description(user, registered_channel, []) do
    if registered_channel.settings.description do
      notify(
        user,
        "\2DESCRIPTION\2 for \2#{registered_channel.name}\2 is: \2#{registered_channel.settings.description}\2"
      )
    else
      notify(user, "No \2DESCRIPTION\2 is set for \2#{registered_channel.name}\2.")
    end
  end

  defp handle_description(user, registered_channel, description) do
    description_text = Enum.join(description, " ")

    if String.trim(description_text) == "" do
      update_setting(user, registered_channel, :description, nil)
    else
      update_setting(user, registered_channel, :description, description_text)
    end
  end

  @spec handle_url(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_url(user, registered_channel, []) do
    if registered_channel.settings.url do
      notify(user, "\2URL\2 for \2#{registered_channel.name}\2 is: \2#{registered_channel.settings.url}\2")
    else
      notify(user, "No \2URL\2 is set for \2#{registered_channel.name}\2.")
    end
  end

  defp handle_url(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :url, nil)
  end

  defp handle_url(user, registered_channel, [url]) do
    update_setting(user, registered_channel, :url, url)
  end

  defp handle_url(user, _registered_channel, _) do
    notify(user, "Syntax: SET <channel> URL <url> or SET <channel> URL OFF to clear")
  end

  @spec handle_email(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_email(user, registered_channel, []) do
    if registered_channel.settings.email do
      notify(user, "\2EMAIL\2 for \2#{registered_channel.name}\2 is: \2#{registered_channel.settings.email}\2")
    else
      notify(user, "No \2EMAIL\2 is set for \2#{registered_channel.name}\2.")
    end
  end

  defp handle_email(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :email, nil)
  end

  defp handle_email(user, registered_channel, [email]) do
    sanitized_email = email |> String.trim() |> String.downcase()

    case validate_email(sanitized_email) do
      :ok -> update_setting(user, registered_channel, :email, sanitized_email)
      {:error, :invalid_email} -> notify(user, "\2#{sanitized_email}\2 is not a valid email address.")
    end
  end

  defp handle_email(user, _registered_channel, _) do
    notify(user, "Syntax: SET <channel> EMAIL <email> or SET <channel> EMAIL OFF to clear")
  end

  @spec handle_entrymsg(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_entrymsg(user, registered_channel, []) do
    if registered_channel.settings.entrymsg do
      notify(
        user,
        "\2ENTRYMSG\2 for \2#{registered_channel.name}\2 is: \2#{registered_channel.settings.entrymsg}\2"
      )
    else
      notify(user, "No \2ENTRYMSG\2 is set for \2#{registered_channel.name}\2.")
    end
  end

  defp handle_entrymsg(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :entrymsg, nil)
  end

  defp handle_entrymsg(user, registered_channel, message) do
    message_text = Enum.join(message, " ")

    if String.trim(message_text) == "" do
      update_setting(user, registered_channel, :entrymsg, nil)
    else
      update_setting(user, registered_channel, :entrymsg, message_text)
    end
  end

  @spec handle_opnotice(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_opnotice(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :opnotice, true)
  end

  defp handle_opnotice(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :opnotice, false)
  end

  defp handle_opnotice(user, _registered_channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2OPNOTICE\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_opnotice(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_peace(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_peace(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :peace, true)
  end

  defp handle_peace(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :peace, false)
  end

  defp handle_peace(user, _registered_channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2PEACE\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_peace(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_secure(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_secure(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :secure, true)
  end

  defp handle_secure(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :secure, false)
  end

  defp handle_secure(user, _registered_channel, [value]) do
    notify(user, "\2#{value}\2 is not a valid setting for \2SECURE\2. Use \2ON\2 or \2OFF\2.")
  end

  defp handle_secure(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_topiclock(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_topiclock(user, registered_channel, []) do
    case registered_channel.settings.topiclock do
      true -> notify(user, "\2TOPICLOCK\2 for \2#{registered_channel.name}\2 is set to: \2ON\2")
      false -> notify(user, "\2TOPICLOCK\2 for \2#{registered_channel.name}\2 is set to: \2OFF\2")
    end
  end

  defp handle_topiclock(user, registered_channel, ["ON"]) do
    update_setting(user, registered_channel, :topiclock, true)
  end

  defp handle_topiclock(user, registered_channel, ["OFF"]) do
    update_setting(user, registered_channel, :topiclock, false)
  end

  defp handle_topiclock(user, _registered_channel, [value]) do
    notify(
      user,
      "\2#{value}\2 is not a valid setting for \2TOPICLOCK\2. Use \2ON\2 or \2OFF\2."
    )
  end

  defp handle_topiclock(user, _registered_channel, _) do
    notify(user, "\2Invalid\2 value. Use \2ON\2 or \2OFF\2.")
  end

  @spec handle_successor(User.t(), RegisteredChannel.t(), [String.t()]) :: :ok
  defp handle_successor(user, registered_channel, []) do
    if registered_channel.successor do
      notify(user, "\2SUCCESSOR\2 for \2#{registered_channel.name}\2 is: \2#{registered_channel.successor}\2")
    else
      notify(user, "No \2SUCCESSOR\2 is set for \2#{registered_channel.name}\2.")
    end
  end

  defp handle_successor(user, registered_channel, ["OFF"]) do
    RegisteredChannels.update(registered_channel, %{successor: nil})
    notify(user, "\2SUCCESSOR\2 for \2#{registered_channel.name}\2 has been unset.")
  end

  defp handle_successor(user, registered_channel, [target_successor]) do
    case RegisteredNicks.get_by_nickname(target_successor) do
      {:ok, registered_nick} ->
        RegisteredChannels.update(registered_channel, %{successor: registered_nick.nickname})

        notify(
          user,
          "\2SUCCESSOR\2 for \2#{registered_channel.name}\2 has been set to: \2#{registered_nick.nickname}\2"
        )

      {:error, :registered_nick_not_found} ->
        notify(user, "Cannot set successor: \2#{target_successor}\2 is not a registered nickname.")
    end
  end

  defp handle_successor(user, _registered_channel, _) do
    notify(user, "Syntax: SET <channel> SUCCESSOR <nickname> or SET <channel> SUCCESSOR OFF to clear")
  end

  @spec update_setting(User.t(), RegisteredChannel.t(), atom(), any()) :: :ok
  defp update_setting(user, registered_channel, setting, value) do
    updated_settings = RegisteredChannel.Settings.update(registered_channel.settings, %{setting => value})
    RegisteredChannels.update(registered_channel, %{settings: updated_settings})

    setting_name = setting |> to_string() |> String.upcase()

    message =
      case value do
        true -> "\2#{setting_name}\2 option for \2#{registered_channel.name}\2 is now \2ON\2"
        false -> "\2#{setting_name}\2 option for \2#{registered_channel.name}\2 is now \2OFF\2"
        nil -> "\2#{setting_name}\2 for \2#{registered_channel.name}\2 has been unset"
        _ -> "\2#{setting_name}\2 for \2#{registered_channel.name}\2 has been set to: \2#{value}\2"
      end

    notify(user, message)
  end
end
