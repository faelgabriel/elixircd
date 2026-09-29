defmodule ElixIRCd.ServerLink.ChannelAdoption do
  @moduledoc "Adopts a selected network channel without granting local creator privileges."

  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Utils.CaseMapping

  @doc "Returns an aligned local channel or creates it with the network identity."
  @spec get_or_create(String.t(), ChannelView.t()) ::
          {:adopted | :existing, Channel.t()} | {:error, :remote_channel_unavailable}
  def get_or_create(name, %ChannelView{} = view) do
    with {:ok, attrs} <- ChannelPayload.to_local(view.channel),
         true <- CaseMapping.normalize(attrs.name) == CaseMapping.normalize(name) do
      case Channels.get_by_name(name) do
        {:ok, channel} -> existing_channel(channel, attrs)
        {:error, :channel_not_found} -> {:adopted, Channels.create(attrs)}
      end
    else
      _ -> {:error, :remote_channel_unavailable}
    end
  end

  defp existing_channel(channel, attrs) do
    creator =
      case Memento.Query.read(ChannelIdentity, channel.name_key) do
        nil -> Application.fetch_env!(:elixircd, :server)[:hostname]
        identity -> identity.creator
      end

    if creator == attrs.creator and DateTime.compare(channel.created_at, attrs.created_at) == :eq and
         MapSet.new(channel.modes) == MapSet.new(attrs.modes) and same_topic?(channel.topic, attrs.topic) do
      {:existing, channel}
    else
      {:error, :remote_channel_unavailable}
    end
  end

  defp same_topic?(nil, nil), do: true

  defp same_topic?(left, right) when not is_nil(left) and not is_nil(right) do
    left.text == right.text and left.setter == right.setter and DateTime.compare(left.set_at, right.set_at) == :eq
  end

  defp same_topic?(_left, _right), do: false
end
