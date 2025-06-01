defmodule ElixIRCd.Services.Chanserv.Register do
  @moduledoc """
  Module for the ChanServ register command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, channel_name?: 1, channel_operator?: 1]

  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["REGISTER", channel_name, password]) do
    config = get_chanserv_config()

    validation_result =
      validate_registration(
        user,
        channel_name,
        password,
        config.min_password_length,
        config.max_channels_per_user,
        config.forbidden_channels
      )

    process_validation_result(
      validation_result,
      user,
      channel_name,
      password,
      config
    )
  end

  def handle(user, ["REGISTER" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02REGISTER\x02.",
      "Syntax: \x02REGISTER <channel> <password>\x02"
    ])
  end

  @spec get_chanserv_config() :: map()
  defp get_chanserv_config do
    chanserv_config = Application.get_env(:elixircd, :services)[:chanserv]

    %{
      min_password_length: chanserv_config[:min_password_length] || 8,
      max_channels_per_user: chanserv_config[:max_registered_channels_per_user] || 10,
      forbidden_channels: chanserv_config[:forbidden_channel_names] || []
    }
  end

  @spec process_validation_result(atom() | {:error, atom()}, User.t(), String.t(), String.t(), map()) :: :ok
  defp process_validation_result(:ok, user, channel_name, password, _config) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, _registered_channel} ->
        notify(user, "The channel \x02#{channel_name}\x02 is already registered.")

      {:error, :registered_channel_not_found} ->
        register_new_channel(user, channel_name, password)
    end
  end

  defp process_validation_result({:error, error_type}, user, channel_name, _password, config) do
    error_handlers = %{
      not_identified: fn ->
        "You must be identified to your nickname to use the \x02REGISTER\x02 command."
      end,
      invalid_channel_name: fn ->
        "\x02#{channel_name}\x02 is not a valid channel name."
      end,
      password_too_short: fn ->
        "Password is too short. Please use at least #{config.min_password_length} characters."
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

  @spec register_new_channel(User.t(), String.t(), String.t()) :: :ok
  defp register_new_channel(user, channel_name, password) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name) do
      if channel_operator?(user_channel) do
        register_channel(user, channel, password)
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

  @spec register_channel(User.t(), Channel.t(), String.t()) :: :ok
  defp register_channel(user, channel, password) do
    password_hash = Argon2.hash_pwd_salt(password)

    RegisteredChannels.create(%{
      name: channel.name,
      founder: user.identified_as,
      password_hash: password_hash,
      registered_by: user_mask(user),
      topic: channel.topic
    })

    notify(user, [
      "Channel \x02#{channel.name}\x02 has been registered under your nickname \x02#{user.identified_as}\x02.",
      "Password accepted.",
      "Remember your password so that you can identify to ChanServ and make changes later!"
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

  @spec validate_registration(User.t(), String.t(), String.t(), integer(), integer(), [String.t() | Regex.t()]) ::
          :ok | {:error, atom()}
  defp validate_registration(user, channel_name, password, min_password_length, max_channels, forbidden_channels) do
    cond do
      is_nil(user.identified_as) ->
        {:error, :not_identified}

      !channel_name?(channel_name) ->
        {:error, :invalid_channel_name}

      String.length(password) < min_password_length ->
        {:error, :password_too_short}

      channel_name_forbidden?(channel_name, forbidden_channels) ->
        {:error, :channel_name_forbidden}

      check_max_channels(user.identified_as, max_channels) == {:error, :limit_reached} ->
        {:error, :max_channels_reached}

      true ->
        :ok
    end
  end
end
