defmodule ElixIRCd.Commands.List do
  @moduledoc """
  This module defines the LIST command.

  LIST returns a list of channels and their topics, with optional filtering.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  defmodule DetailedChannel do
    @moduledoc "A channel and its effective network member count for LIST filtering."

    alias ElixIRCd.Tables.Channel

    @enforce_keys [:channel, :users_count]
    defstruct [:channel, :users_count]

    @type t :: %__MODULE__{channel: Channel.t(), users_count: non_neg_integer()}
  end

  @type detailed_channel :: DetailedChannel.t()

  @type filter ::
          {:users_greater, integer()}
          | {:users_less, integer()}
          | {:created_older, integer()}
          | {:created_newer, integer()}
          | {:topic_older, integer()}
          | {:topic_newer, integer()}
          | {:name_match, String.t()}
          | {:name_not_match, String.t()}
          | {:exact_name, String.t()}

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "LIST"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "LIST", params: params}) do
    search_string = Enum.at(params, 0, nil)

    handle_list(search_string, user)
    |> Enum.sort_by(& &1.channel.name)
    |> Enum.map(fn detailed_channel ->
      name = detailed_channel.channel.name
      topic = if detailed_channel.channel.topic, do: detailed_channel.channel.topic.text, else: "No topic is set"
      users_count = detailed_channel.users_count

      %Message{command: :rpl_list, params: [user.nick, name, users_count], trailing: topic}
    end)
    |> Dispatcher.broadcast(:server, user)

    %Message{command: :rpl_listend, params: [user.nick], trailing: "End of LIST"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_list(String.t(), User.t()) :: [detailed_channel()]
  defp handle_list(search_string, user) do
    case network_views() do
      :unavailable -> []
      views -> filter_network_channels(views, search_string, user)
    end
  end

  defp filter_network_channels(views, search_string, user) do
    {general_filters, channel_name_filters} = parse_filters(search_string)
    exact_keys = MapSet.new(channel_name_filters, fn {:exact_name, name} -> CaseMapping.normalize(name) end)

    views
    |> network_channels()
    |> Enum.filter(&(MapSet.size(exact_keys) == 0 or MapSet.member?(exact_keys, &1.name_key)))
    |> filter_out_hidden_channels(user)
    |> convert_to_detailed_channels(views)
    |> apply_general_filters(general_filters)
  end

  defp network_views do
    case ChannelDirectory.all() do
      views when is_list(views) -> Map.new(views, &{CaseMapping.normalize(&1.channel["name"]), &1})
      :unavailable -> if(Application.fetch_env!(:elixircd, :server_links)[:enabled], do: :unavailable, else: %{})
    end
  end

  defp network_channels(views) do
    links_enabled? = Application.fetch_env!(:elixircd, :server_links)[:enabled]

    local =
      Channels.get_all()
      |> Enum.filter(&(not links_enabled? or Map.has_key?(views, &1.name_key)))
      |> Map.new(&{&1.name_key, &1})

    local_id = Application.fetch_env!(:elixircd, :server)[:hostname]

    Enum.reduce(views, local, fn {key, view}, channels ->
      add_remote_channel(channels, key, view, local_id)
    end)
    |> Map.values()
  end

  defp add_remote_channel(channels, _key, %{origin: local_id}, local_id), do: channels

  defp add_remote_channel(channels, key, view, _local_id) do
    case ChannelPayload.to_local(view.channel) do
      {:ok, attrs} -> Map.put(channels, key, attrs |> Map.delete(:creator) |> Channel.new())
      {:error, :invalid_channel} -> channels
    end
  end

  @spec parse_filters(String.t()) :: {[filter()], [filter()]}
  defp parse_filters(nil), do: {[], []}

  defp parse_filters(search_string) do
    search_string
    |> String.split(",")
    |> Enum.map(&parse_filter/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce({[], []}, fn
      {:exact_name, _} = filter, {general, exact} -> {general, [filter | exact]}
      filter, {general, exact} -> {[filter | general], exact}
    end)
  end

  @spec parse_filter(String.t()) :: filter() | nil
  defp parse_filter(">" <> value), do: parse_numeric_filter(:users_greater, value)
  defp parse_filter("<" <> value), do: parse_numeric_filter(:users_less, value)
  defp parse_filter("C>" <> value), do: parse_numeric_filter(:created_older, value)
  defp parse_filter("C<" <> value), do: parse_numeric_filter(:created_newer, value)
  defp parse_filter("T>" <> value), do: parse_numeric_filter(:topic_older, value)
  defp parse_filter("T<" <> value), do: parse_numeric_filter(:topic_newer, value)

  defp parse_filter(value) do
    cond do
      String.starts_with?(value, "!") ->
        {:name_not_match, value |> String.trim_leading("!") |> ensure_channel_pattern()}

      String.contains?(value, ["*", "?"]) ->
        {:name_match, ensure_channel_pattern(value)}

      true ->
        {:exact_name, ensure_channel_pattern(value)}
    end
  end

  @spec ensure_channel_pattern(String.t()) :: String.t()
  defp ensure_channel_pattern(value) do
    if String.starts_with?(value, ["#", "&"]), do: value, else: "#" <> value
  end

  @spec parse_numeric_filter(atom(), String.t()) :: {atom(), integer()} | nil
  defp parse_numeric_filter(type, value) do
    case Integer.parse(value) do
      {num, ""} -> {type, num}
      _ -> nil
    end
  end

  @spec filter_out_hidden_channels([Channel.t()], User.t()) :: [Channel.t()]
  defp filter_out_hidden_channels(channels, user) do
    user_channel_names =
      UserChannels.get_by_user_pid(user.pid)
      |> Enum.map(& &1.channel_name_key)

    Enum.reject(channels, fn channel ->
      hidden_by_modes?(channel, user_channel_names) or registered_channel_private?(channel, user)
    end)
  end

  @spec hidden_by_modes?(Channel.t(), [String.t()]) :: boolean()
  defp hidden_by_modes?(channel, user_channel_names) do
    local_hidden? =
      case Channels.get_by_name(channel.name) do
        {:ok, local} -> :p in local.modes or :s in local.modes
        _ -> false
      end

    (:p in channel.modes or :s in channel.modes or local_hidden?) and
      not Enum.member?(user_channel_names, channel.name_key)
  end

  @spec registered_channel_private?(Channel.t(), User.t()) :: boolean()
  defp registered_channel_private?(channel, user) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, %{settings: %{private: true}, founder: founder}} ->
        not Enum.any?(UserChannels.get_by_user_pid(user.pid), &(&1.channel_name_key == channel.name_key)) and
          user.identified_as != founder

      _ ->
        false
    end
  end

  @spec convert_to_detailed_channels([Channel.t()], map()) :: [detailed_channel()]
  defp convert_to_detailed_channels(channels, views) do
    channels_with_users_count =
      channels
      |> Enum.map(& &1.name)
      |> UserChannels.count_users_by_channel_names()
      |> Map.new()

    Enum.map(channels, fn channel ->
      remote_count =
        case Map.get(views, channel.name_key) do
          nil -> 0
          view -> length(view.remote_members)
        end

      %DetailedChannel{channel: channel, users_count: Map.get(channels_with_users_count, channel.name) + remote_count}
    end)
  end

  @spec apply_general_filters([detailed_channel()], [tuple()]) :: [detailed_channel()]
  defp apply_general_filters(detailed_channel, []), do: detailed_channel

  defp apply_general_filters(detailed_channel, filters) do
    Enum.filter(detailed_channel, fn detailed_channel ->
      Enum.all?(filters, fn filter -> check_filter(filter, detailed_channel) end)
    end)
  end

  @spec check_filter(filter(), detailed_channel()) :: boolean
  defp check_filter({:users_greater, val}, detailed_channel), do: detailed_channel.users_count > val
  defp check_filter({:users_less, val}, detailed_channel), do: detailed_channel.users_count < val

  defp check_filter({:created_newer, val}, detailed_channel) do
    created_at = detailed_channel.channel.created_at
    now = DateTime.utc_now()
    minutes_ago = DateTime.add(now, -val, :minute)
    DateTime.compare(created_at, minutes_ago) != :lt and DateTime.compare(created_at, now) != :gt
  end

  defp check_filter({:created_older, val}, detailed_channel) do
    created_at = detailed_channel.channel.created_at
    now = DateTime.utc_now()
    minutes_ago = DateTime.add(now, -val, :minute)
    DateTime.compare(created_at, minutes_ago) == :lt
  end

  defp check_filter({:topic_older, val}, detailed_channel) do
    case detailed_channel.channel.topic do
      %{set_at: set_at} ->
        minutes_ago = DateTime.add(DateTime.utc_now(), -val, :minute)
        DateTime.compare(set_at, minutes_ago) == :lt

      nil ->
        false
    end
  end

  defp check_filter({:topic_newer, val}, detailed_channel) do
    case detailed_channel.channel.topic do
      %{set_at: set_at} ->
        minutes_ago = DateTime.add(DateTime.utc_now(), -val, :minute)
        DateTime.compare(set_at, minutes_ago) != :lt

      nil ->
        false
    end
  end

  defp check_filter({:name_match, pattern}, detailed_channel),
    do: Protocol.match_glob?(detailed_channel.channel.name, pattern)

  defp check_filter({:name_not_match, pattern}, detailed_channel),
    do: not Protocol.match_glob?(detailed_channel.channel.name, pattern)
end
