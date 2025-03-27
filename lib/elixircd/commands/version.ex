defmodule ElixIRCd.Commands.Version do
  @moduledoc """
  This module defines the VERSION command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "VERSION"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "VERSION"}) do
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]
    elixircd_version = Application.spec(:elixircd, :vsn)

    Message.build(%{
      prefix: :server,
      command: :rpl_version,
      params: [user.nick, "ElixIRCd-#{elixircd_version}", server_hostname]
    })
    |> Dispatcher.broadcast(user)

    # Feature: implements RPL_ISUPPORT - https://modern.ircdocs.horse/#feature-advertisement
    # :irc.example.com 005 MyNick MODES=4 MAXCHANNELS=20 CHANLIMIT=#&:20 PREFIX=(ov)@+ NETWORK=ExampleIRC :are supported by this server
    # :irc.example.com 005 MyNick CHANTYPES=#& TOPICLEN=300 AWAYLEN=160 NICKLEN=30 CASEMAPPING=rfc1459 :are supported by this server
    # MODES=4: Maximum number of mode changes allowed per MODE command.
    # MAXCHANNELS=20: Maximum number of channels a user can join.
    # CHANLIMIT=#&:20: Maximum number of # or & channels a user can join.
    # PREFIX=(ov)@+: User modes o (operator, @) and v (voice, +) are supported.
    # NETWORK=ExampleIRC: Name of the IRC network.
    # CHANTYPES=#&: Supported channel prefixes are # and &.
    # TOPICLEN=300: Maximum length for a channel topic is 300 characters.
    # AWAYLEN=160: Maximum length for an away message is 160 characters.
    # NICKLEN=30: Maximum length for nicknames is 30 characters.
    # CASEMAPPING=rfc1459: Uses RFC 1459 rules for case-insensitivity in nicknames and channel names.
  end
end
