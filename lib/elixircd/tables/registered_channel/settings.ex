defmodule ElixIRCd.Tables.RegisteredChannel.Settings do
  @moduledoc """
  Module for the RegisteredChannel.Settings data structure.

  Stores channel-configurable options set via the ChanServ SET command.
  """

  defstruct [
    # SET DESCRIPTION - Channel description text
    :description,
    # SET URL - Channel's website URL
    :url,
    # SET EMAIL - Contact email address
    :email,
    # SET ENTRYMSG - Welcome message shown to joining users
    :entrymsg,
    # SET KEEPTOPIC - Preserve topic when channel is empty
    :keeptopic,
    # Persistent topic to restore when KEEPTOPIC is ON
    :persistent_topic,
    # SET OPNOTICE - Notify ops when users join
    :opnotice,
    # SET PEACE - Prevent operators from kicking/banning other operators
    :peace,
    # SET PRIVATE - Hide channel from LIST command
    :private,
    # SET RESTRICTED - Only allow identified users to join
    :restricted,
    # SET SECURE - Enforce stricter security measures
    :secure,
    # SET FANTASY - Enable !commands in channel
    :fantasy,
    # SET GUARD - Keep ChanServ in the channel
    :guard,
    # SET TOPICLOCK - Control who can change the topic (true=ON, false=OFF)
    :topiclock,
    # SET MLOCK - Mode lock configuration for the channel
    :mlock
  ]

  @type t :: %__MODULE__{
          # Channel Information
          description: String.t() | nil,
          url: String.t() | nil,
          email: String.t() | nil,
          entrymsg: String.t() | nil,

          # Topic Control
          keeptopic: boolean(),
          persistent_topic: String.t() | nil,
          topiclock: boolean(),

          # Security & Behavior
          opnotice: boolean(),
          peace: boolean(),
          private: boolean(),
          restricted: boolean(),
          secure: boolean(),

          # Bot Presence
          fantasy: boolean(),
          guard: boolean(),

          # Mode Control
          mlock: String.t() | nil
        }

  @type t_attrs :: %{
          optional(:description) => String.t() | nil,
          optional(:url) => String.t() | nil,
          optional(:email) => String.t() | nil,
          optional(:entrymsg) => String.t() | nil,
          optional(:keeptopic) => boolean(),
          optional(:persistent_topic) => String.t() | nil,
          optional(:topiclock) => boolean(),
          optional(:opnotice) => boolean(),
          optional(:peace) => boolean(),
          optional(:private) => boolean(),
          optional(:restricted) => boolean(),
          optional(:secure) => boolean(),
          optional(:fantasy) => boolean(),
          optional(:guard) => boolean(),
          optional(:mlock) => String.t() | nil
        }

  @doc """
  Create a new settings struct with default values.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs \\ %{}) do
    config_settings = get_config_settings()

    new_attrs =
      attrs
      |> init_channel_info(config_settings)
      |> init_topic_control(config_settings)
      |> init_security_behavior(config_settings)
      |> init_bot_presence(config_settings)
      |> init_mode_control(config_settings)

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Update settings struct with new attributes.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(settings, attrs) do
    struct!(settings, attrs)
  end

  @spec get_config_settings() :: keyword()
  defp get_config_settings do
    Application.get_env(:elixircd, :services, [])
    |> Keyword.get(:chanserv, [])
    |> Keyword.get(:settings, [])
  end

  @spec init_channel_info(t_attrs(), keyword()) :: t_attrs()
  defp init_channel_info(attrs, config_settings) do
    attrs
    |> Map.put_new(:description, nil)
    |> Map.put_new(:url, nil)
    |> Map.put_new(:email, nil)
    |> Map.put_new(:entrymsg, config_settings[:entrymsg])
  end

  @spec init_topic_control(t_attrs(), keyword()) :: t_attrs()
  defp init_topic_control(attrs, config_settings) do
    attrs
    |> Map.put_new(:keeptopic, config_settings[:keeptopic] || true)
    |> Map.put_new(:persistent_topic, nil)
    |> Map.put_new(:topiclock, config_settings[:topiclock] || false)
  end

  @spec init_security_behavior(t_attrs(), keyword()) :: t_attrs()
  defp init_security_behavior(attrs, config_settings) do
    attrs
    |> Map.put_new(:opnotice, config_settings[:opnotice] || true)
    |> Map.put_new(:peace, config_settings[:peace] || false)
    |> Map.put_new(:private, config_settings[:private] || false)
    |> Map.put_new(:restricted, config_settings[:restricted] || false)
    |> Map.put_new(:secure, config_settings[:secure] || false)
  end

  @spec init_bot_presence(t_attrs(), keyword()) :: t_attrs()
  defp init_bot_presence(attrs, config_settings) do
    attrs
    |> Map.put_new(:fantasy, config_settings[:fantasy] || true)
    |> Map.put_new(:guard, config_settings[:guard] || true)
  end

  @spec init_mode_control(t_attrs(), keyword()) :: t_attrs()
  defp init_mode_control(attrs, config_settings) do
    attrs
    |> Map.put_new(:mlock, config_settings[:mlock])
  end
end
