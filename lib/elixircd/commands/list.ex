defmodule ElixIRCd.Commands.List do
  @moduledoc """
  This module defines the LIST command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User

  @type detailed_channel :: %{
          channel: Channel.t(),
          users_count: integer()
        }

  @type filter ::
          {:users_greater, integer()}
          | {:users_less, integer()}
          | {:created_after, integer()}
          | {:created_before, integer()}
          | {:topic_older, integer()}
          | {:topic_newer, integer()}
          | {:name_match, String.t()}
          | {:name_not_match, String.t()}
          | {:exact_name, String.t()}

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "LIST"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
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

      Message.build(%{prefix: :server, command: :rpl_list, params: [user.nick, name, users_count], trailing: topic})
    end)
    |> Dispatcher.broadcast(user)

    Message.build(%{prefix: :server, command: :rpl_listend, params: [user.nick], trailing: "End of LIST"})
    |> Dispatcher.broadcast(user)
  end

  @spec handle_list(String.t(), User.t()) :: [detailed_channel()]
  defp handle_list(search_string, user) do
    {general_filters, channel_name_filters} = parse_filters(search_string)

    channels =
      channel_name_filters
      |> Enum.map(fn {:exact_name, name} -> name end)
      |> case do
        [] -> Channels.get_all()
        channel_names -> Channels.get_by_names(channel_names)
      end

    channels
    |> filter_out_hidden_channels(user)
    |> convert_to_detailed_channels()
    |> apply_general_filters(general_filters)
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
  defp parse_filter("C>" <> value), do: parse_numeric_filter(:created_after, value)
  defp parse_filter("C<" <> value), do: parse_numeric_filter(:created_before, value)
  defp parse_filter("T>" <> value), do: parse_numeric_filter(:topic_older, value)
  defp parse_filter("T<" <> value), do: parse_numeric_filter(:topic_newer, value)
  defp parse_filter("#" <> value), do: {:exact_name, "#" <> value}

  defp parse_filter(value) do
    cond do
      # Regex to match string that starts and ends with "*"
      Regex.match?(~r/^\*(.*?)\*$/, value) -> {:name_match, Regex.replace(~r/^\*|\*$/, value, "")}
      # Regex to match string that starts with "!*" and ends with "*"
      Regex.match?(~r/^!\*(.*?)\*$/, value) -> {:name_not_match, Regex.replace(~r/^!\*|\*$/, value, "")}
      # Default case to consider the value as an exact name filter
      true -> {:exact_name, "#" <> value}
    end
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
      |> Enum.map(& &1.channel_name)

    Enum.reject(channels, fn channel ->
      ("p" in channel.modes or "s" in channel.modes) and not Enum.member?(user_channel_names, channel.name)
    end)
  end

  @spec convert_to_detailed_channels([Channel.t()]) :: [detailed_channel()]
  defp convert_to_detailed_channels(channels) do
    channels_with_users_count =
      channels
      |> Enum.map(& &1.name)
      |> UserChannels.count_users_by_channel_names()
      |> Map.new()

    Enum.map(channels, fn channel ->
      %{channel: channel, users_count: Map.get(channels_with_users_count, channel.name)}
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

  defp check_filter({:created_after, val}, detailed_channel) do
    created_at = detailed_channel.channel.created_at
    now = DateTime.utc_now()
    minutes_ago = DateTime.add(now, -val, :minute)
    DateTime.compare(created_at, minutes_ago) != :lt and DateTime.compare(created_at, now) != :gt
  end

  defp check_filter({:created_before, val}, detailed_channel) do
    created_at = detailed_channel.channel.created_at
    now = DateTime.utc_now()
    minutes_ago = DateTime.add(now, -val, :minute)
    DateTime.compare(created_at, minutes_ago) == :lt
  end

  defp check_filter({:topic_older, val}, detailed_channel) do
    set_at = detailed_channel.channel.topic.set_at
    minutes_ago = DateTime.add(DateTime.utc_now(), -val, :minute)
    DateTime.compare(set_at, minutes_ago) == :lt
  end

  defp check_filter({:topic_newer, val}, detailed_channel) do
    set_at = detailed_channel.channel.topic.set_at
    minutes_ago = DateTime.add(DateTime.utc_now(), -val, :minute)
    DateTime.compare(set_at, minutes_ago) != :lt
  end

  defp check_filter({:name_match, match}, detailed_channel),
    do: Regex.match?(~r/#{Regex.escape(match)}/, detailed_channel.channel.name)

  defp check_filter({:name_not_match, match}, detailed_channel),
    do: not Regex.match?(~r/#{Regex.escape(match)}/, detailed_channel.channel.name)
end
