defmodule ElixIRCd.Services.Chanserv.Channel.Context do
  @moduledoc false

  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Chanserv.Flags

  @doc false
  @spec get_registered_channel(String.t()) :: {:ok, RegisteredChannel.t()} | {:error, :registered_channel_not_found}
  def get_registered_channel(channel_name), do: RegisteredChannels.get_by_name(channel_name)

  @doc false
  @spec get_access_entries(String.t()) :: %{optional(String.t()) => String.t()}
  def get_access_entries(channel_name) do
    channel_name
    |> RegisteredChannelAccesses.get_flags_map_by_channel_name()
    |> Flags.normalize_access_entries()
  end

  @doc false
  @spec get_online_channel(String.t()) :: {:ok, Channel.t()} | {:error, :channel_not_in_use}
  def get_online_channel(channel_name) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} -> {:ok, channel}
      {:error, :channel_not_found} -> {:error, :channel_not_in_use}
    end
  end

  @doc false
  @spec get_online_channel_state(String.t()) ::
          {:ok, Channel.t(), [UserChannel.t()], [User.t()]} | {:error, :channel_not_in_use}
  def get_online_channel_state(channel_name) do
    case get_online_channel(channel_name) do
      {:ok, channel} ->
        user_channels = UserChannels.get_by_channel_name(channel.name)
        user_pids = Enum.map(user_channels, & &1.user_pid)

        {:ok, channel, user_channels, Users.get_by_pids(user_pids)}

      {:error, :channel_not_in_use} = error ->
        error
    end
  end
end
