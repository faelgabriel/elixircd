defmodule ElixIRCd.Services.Chanserv.Register do
  @moduledoc """
  This module defines the ChanServ REGISTER command.

  REGISTER allows users to register channels with ChanServ.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, channel_name?: 1, channel_operator?: 1]

  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["REGISTER", channel_name]) do
    config = get_chanserv_config()

    validation_result =
      validate_registration(
        user,
        channel_name,
        config.max_channels_per_user,
        config.forbidden_channels
      )

    process_validation_result(
      validation_result,
      user,
      channel_name,
      config
    )
  end

  def handle(user, ["REGISTER" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02REGISTER\x02.",
      "Syntax: \x02REGISTER <channel>\x02"
    ])
  end

  @spec get_chanserv_config() :: map()
  defp get_chanserv_config do
    chanserv_config = Application.fetch_env!(:elixircd, :services)[:chanserv]

    %{
      max_channels_per_user: chanserv_config[:max_registered_channels_per_user],
      forbidden_channels: chanserv_config[:forbidden_channel_names]
    }
  end

  @spec process_validation_result(atom() | {:error, atom()}, User.t(), String.t(), map()) :: :ok
  defp process_validation_result(:ok, user, channel_name, _config) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, _registered_channel} ->
        notify(user, "The channel \x02#{channel_name}\x02 is already registered.")

      {:error, :registered_channel_not_found} ->
        register_new_channel(user, channel_name)
    end
  end

  defp process_validation_result({:error, error_type}, user, channel_name, config) do
    error_handlers = %{
      not_identified: fn ->
        "You must be identified to your nickname to use the \x02REGISTER\x02 command."
      end,
      invalid_channel_name: fn ->
        "\x02#{channel_name}\x02 is not a valid channel name."
      end,
      channel_name_forbidden: fn ->
        "The channel name \x02#{channel_name}\x02 cannot be registered due to network policy."
      end,
      max_channels_reached: fn ->
        "You have reached the maximum number of registered channels (#{config.max_channels_per_user})."
      end
    }

    error_message = error_handlers[error_type].()
    notify(user, error_message)
  end

  @spec register_new_channel(User.t(), String.t()) :: :ok
  defp register_new_channel(user, channel_name) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name) do
      if channel_operator?(user_channel) do
        register_channel(user, channel)
      else
        notify(user, "You must be a channel operator in \x02#{channel_name}\x02 to register it.")
      end
    else
      {:error, :channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 does not exist. Please join the channel before registering.")

      {:error, :user_channel_not_found} ->
        notify(user, "You are not in channel \x02#{channel_name}\x02. Please join the channel first.")
    end
  end

  @spec register_channel(User.t(), Channel.t()) :: :ok
  defp register_channel(user, channel) do
    RegisteredChannels.create(%{
      name: channel.name,
      founder: user.identified_as,
      registered_by: user_mask(user),
      topic: channel.topic,
      settings: RegisteredChannel.Settings.new(%{persistent_topic: topic_text(channel.topic)})
    })

    notify(user, [
      "Channel \x02#{channel.name}\x02 has been registered under your account \x02#{user.identified_as}\x02.",
      "Identify to your NickServ account to manage this channel."
    ])
  end

  @spec check_max_channels(String.t(), integer()) :: :ok | {:error, :limit_reached}
  defp check_max_channels(account_name, max_channels) do
    channels_count = length(RegisteredChannels.get_by_founder(account_name))

    if channels_count >= max_channels do
      {:error, :limit_reached}
    else
      :ok
    end
  end

  @spec channel_name_forbidden?(String.t(), [String.t() | Regex.t()]) :: boolean()
  defp channel_name_forbidden?(channel_name, forbidden_channels) do
    Enum.any?(forbidden_channels, fn pattern ->
      case pattern do
        pattern when is_binary(pattern) -> pattern == channel_name
        %Regex{} = regex -> Regex.match?(regex, channel_name)
      end
    end)
  end

  @spec topic_text(Channel.Topic.t() | nil) :: String.t() | nil
  defp topic_text(nil), do: nil
  defp topic_text(%Channel.Topic{text: text}), do: text

  @spec validate_registration(User.t(), String.t(), integer(), [String.t() | Regex.t()]) ::
          :ok | {:error, atom()}
  defp validate_registration(user, channel_name, max_channels, forbidden_channels) do
    cond do
      is_nil(user.identified_as) ->
        {:error, :not_identified}

      !channel_name?(channel_name) ->
        {:error, :invalid_channel_name}

      channel_name_forbidden?(channel_name, forbidden_channels) ->
        {:error, :channel_name_forbidden}

      check_max_channels(user.identified_as, max_channels) == {:error, :limit_reached} ->
        {:error, :max_channels_reached}

      true ->
        :ok
    end
  end
end
