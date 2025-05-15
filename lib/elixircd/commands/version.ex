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
    all_features = get_all_feature_tokens()

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

  @spec get_all_feature_tokens() :: [String.t()]
  defp get_all_feature_tokens do
    user_config = Application.get_env(:elixircd, :user)
    channel_config = Application.get_env(:elixircd, :channel)
    server_config = Application.get_env(:elixircd, :server)
    features_config = Application.get_env(:elixircd, :features)

    [
      format_feature(:numeric, "MODES", channel_config[:modes]),
      format_feature(:map, "CHANLIMIT", channel_config[:chanlimit]),
      format_feature(:prefix, "PREFIX", channel_config[:prefix]),
      format_feature(:string, "CHANTYPES", channel_config[:chantypes]),
      format_feature(:numeric, "NICKLEN", user_config[:nicklen]),
      format_feature(:string, "NETWORK", server_config[:name]),
      format_feature(:string, "CASEMAPPING", features_config[:casemapping]),
      format_feature(:numeric, "TOPICLEN", channel_config[:topiclen]),
      format_feature(:numeric, "KICKLEN", channel_config[:kicklen]),
      format_feature(:numeric, "AWAYLEN", user_config[:awaylen]),
      format_feature(:numeric, "MONITOR", features_config[:monitor]),
      format_feature(:numeric, "SILENCE", features_config[:silence]),
      format_feature(:string, "CHANMODES", channel_config[:chanmodes]),
      format_feature(:map, "TARGMAX", channel_config[:targmax]),
      format_feature(:string, "STATUSMSG", channel_config[:statusmsg]),
      format_feature(:boolean, "EXCEPTS", channel_config[:excepts]),
      format_feature(:boolean, "INVEX", channel_config[:invex]),
      format_feature(:boolean, "UHNAMES", features_config[:uhnames]),
      format_feature(:boolean, "CALLERID", features_config[:callerid])
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec format_feature(atom(), String.t(), any()) :: String.t() | nil
  defp format_feature(:map, name, map) do
    sep = ":"
    join_char = ","
    formatted_map = Enum.map_join(map, join_char, fn {key, val} -> "#{key}#{sep}#{val}" end)
    "#{name}=#{formatted_map}"
  end

  defp format_feature(:numeric, name, value), do: "#{name}=#{value}"
  defp format_feature(:string, name, value), do: "#{name}=#{value}"
  defp format_feature(:prefix, name, %{modes: modes, prefixes: prefixes}), do: "#{name}=(#{modes})#{prefixes}"
  defp format_feature(:boolean, _name, false), do: nil
  defp format_feature(:boolean, name, true), do: name
end
