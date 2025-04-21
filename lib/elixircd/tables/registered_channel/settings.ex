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
    :entry_message,
    # SET KEEPTOPIC - Preserve topic when channel is empty
    :keeptopic,
    # Persistent topic to restore when KEEPTOPIC is ON
    :persistent_topic,
    # SET OPNOTICE - Notify ops when users join
    :op_notice,
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
    :topiclock
  ]

  @type t :: %__MODULE__{
          # Channel Information
          description: String.t() | nil,
          url: String.t() | nil,
          email: String.t() | nil,
          entry_message: String.t() | nil,

          # Topic Control
          keeptopic: boolean(),
          persistent_topic: String.t() | nil,
          topiclock: boolean(),

          # Security & Behavior
          op_notice: boolean(),
          peace: boolean(),
          private: boolean(),
          restricted: boolean(),
          secure: boolean(),

          # Bot Presence
          fantasy: boolean(),
          guard: boolean()
        }

  @doc """
  Create a new settings struct with default values.
  """
  @spec new() :: t()
  def new do
    config_settings = get_config_settings()

    %__MODULE__{
      # Channel Information
      description: nil,
      url: nil,
      email: nil,
      entry_message: config_settings[:entry_message],

      # Topic Control
      keeptopic: config_settings[:keeptopic] || true,
      persistent_topic: nil,
      topiclock: config_settings[:topiclock] || false,

      # Security & Behavior
      op_notice: config_settings[:op_notice] || true,
      peace: config_settings[:peace] || false,
      private: config_settings[:private] || false,
      restricted: config_settings[:restricted] || false,
      secure: config_settings[:secure] || false,

      # Bot Presence
      fantasy: config_settings[:fantasy] || true,
      guard: config_settings[:guard] || true
    }
  end

  @doc """
  Update settings struct with new attributes.
  """
  @spec update(t(), map() | keyword()) :: t()
  def update(settings, attrs) do
    struct!(settings, attrs)
  end

  @spec get_config_settings() :: keyword()
  defp get_config_settings do
    Application.get_env(:elixircd, :services, [])
    |> Keyword.get(:chanserv, [])
    |> Keyword.get(:settings, [])
  end
end
