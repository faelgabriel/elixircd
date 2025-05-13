defmodule ElixIRCd.Commands.Version do
  @moduledoc """
  This module defines the VERSION command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  # Maximum number of feature tokens per ISUPPORT message
  @max_features_per_batch 5

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "VERSION"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "VERSION"}) do
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]
    elixircd_version = Application.spec(:elixircd, :vsn)

    Message.build(%{
      prefix: :server,
      command: :rpl_version,
      params: [user.nick, "ElixIRCd-#{elixircd_version}", server_hostname]
    })
    |> Dispatcher.broadcast(user)

    send_isupport_messages(user)
  end

  @spec send_isupport_messages(User.t()) :: :ok
  defp send_isupport_messages(user) do
    user_config = Application.get_env(:elixircd, :user)
    channel_config = Application.get_env(:elixircd, :channel)

    all_features = get_all_feature_tokens(channel_config, user_config)

    all_features
    |> Enum.chunk_every(@max_features_per_batch)
    |> Enum.each(fn feature_batch ->
      Message.build(%{
        prefix: :server,
        command: :rpl_isupport,
        params: [user.nick | feature_batch],
        trailing: "are supported by this server"
      })
      |> Dispatcher.broadcast(user)
    end)
  end

  @spec get_all_feature_tokens(map(), map()) :: [String.t()]
  defp get_all_feature_tokens(channel_config, user_config) do
    standard_features = [
      "MODES=#{channel_config[:modes]}",
      "CHANLIMIT=#{format_map_to_list(channel_config[:chanlimit], ":", ",")}",
      "PREFIX=#{format_prefix(channel_config[:prefix])}",
      "NETWORK=#{channel_config[:network]}",
      "CHANTYPES=#{channel_config[:chantypes]}",
      "TOPICLEN=#{channel_config[:topiclen]}",
      "KICKLEN=#{channel_config[:kicklen]}",
      "AWAYLEN=#{user_config[:awaylen]}",
      "NICKLEN=#{user_config[:nicklen]}",
      "CASEMAPPING=#{user_config[:casemapping]}",
      "CHANMODES=#{channel_config[:chanmodes]}",
      "MONITOR=#{user_config[:monitor]}",
      "SILENCE=#{user_config[:silence]}",
      "TARGMAX=#{format_map_to_list(channel_config[:targmax], ":", ",")}",
      "STATUSMSG=#{channel_config[:statusmsg]}"
    ]

    boolean_features =
      [
        if(channel_config[:excepts], do: "EXCEPTS"),
        if(channel_config[:invex], do: "INVEX"),
        if(channel_config[:uhnames], do: "UHNAMES"),
        if(user_config[:callerid], do: "CALLERID")
      ]
      |> Enum.reject(&is_nil/1)

    standard_features ++ boolean_features
  end

  # Format prefix data in the required format: (modes)prefixes
  @spec format_prefix(%{modes: String.t(), prefixes: String.t()}) :: String.t()
  defp format_prefix(%{modes: modes, prefixes: prefixes}), do: "(#{modes})#{prefixes}"

  # Format map data into IRC-style lists
  @spec format_map_to_list(map(), String.t(), String.t()) :: String.t()
  defp format_map_to_list(map, sep, join_char) when is_map(map) do
    Enum.map_join(map, join_char, fn {key, val} -> "#{key}#{sep}#{val}" end)
  end
end
