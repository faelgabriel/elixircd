defmodule ElixIRCd.Tables.RegisteredNick.Settings do
  @moduledoc """
  Module for the RegisteredNick.Settings data structure.

  Stores user-configurable options set via the NickServ SET command.
  """

  defstruct [
    # # SET EMAIL <address> - Associated email address
    # :email,
    # # SET EMAILMEMOS {ON|OFF|ONLY} - Forward memos to email
    # :email_memos,
    # # SET ENFORCE {ON|OFF} - Master switch for nick enforcement (often enables KILL)
    # :enforce,
    # # SET ENFORCETIME <seconds> - Delay before enforcement action
    # :enforce_time,
    # SET HIDE EMAIL {ON|OFF} - Hide email in /NS INFO
    :hide_email
    # # SET HIDE STATUS {ON|OFF} - Hide login status in /NS INFO
    # :hide_status,
    # # SET HIDE USERMASK {ON|OFF} - Hide user@host mask in /NS INFO (aka MASK)
    # :hide_usermask,
    # # SET HIDE QUIT {ON|OFF} - Hide last quit message/time in /NS INFO
    # :hide_quit,
    # # SET KILL {ON|QUICK|IMMED|OFF} - Action taken on unauthorized nick usage
    # :kill,
    # # SET LANGUAGE <language_code> - Preferred language for services messages
    # :language,
    # # SET MSG {ON|OFF} - Use PRIVMSG (true/ON) or NOTICE (false/OFF) for services messages
    # :msg,
    # # SET NEVERGROUP {ON|OFF} - Require confirmation for grouping requests
    # :never_group,
    # # SET NEVEROP {ON|OFF} - Prevent services from auto-opping in channels
    # :never_op,
    # # SET NOGREET {ON|OFF} - Suppress ChanServ GREET messages on channel join
    # :no_greet,
    # # SET PRIVATE {ON|OFF} - Hide nick from public lists like /NS LIST
    # :private,
    # # SET PROPERTY <name> [value] - Store custom key-value metadata
    # :property,
    # # SET PUBKEY [key] - Store public key for SASL ECDSA-NIST256p-CHALLENGE
    # :pubkey,
    # # SET QUIETCHG {ON|OFF} - Suppress ChanServ mode/flag change notices for self
    # :quiet_chg,
    # # SET SECURE {ON|OFF} - Enable stricter session validation / ghost killing
    # :secure,
    # # SET URL <url> - Associate a URL, shown in /NS INFO
    # :url,
    # # SET DISPLAY <nick_in_group> - Set the display nick for a group (Module-dependent)
    # :display
  ]

  @type t :: %__MODULE__{
          # # User Information
          # email: String.t() | nil,
          # url: String.t() | nil,
          # # e.g., "en", "fr"
          # language: String.t() | nil,
          # # Map of custom properties SET PROPERTY <key> <value>
          # property: %{String.t() => String.t()},
          # # Nickname to display for the group (SET DISPLAY)
          # display: String.t() | nil,

          # Hiding Information
          # SET HIDE EMAIL
          hide_email: boolean()
          # # SET HIDE STATUS
          # hide_status: boolean(),
          # # SET HIDE USERMASK (or MASK)
          # hide_usermask: boolean(),
          # # SET HIDE QUIT
          # hide_quit: boolean(),
          # # SET PRIVATE (Hide from LIST etc.)
          # private: boolean(),

          # # Enforcement
          # # SET ENFORCE ON/OFF (Master switch for KILL etc.)
          # enforce: boolean(),
          # # SET ENFORCETIME <seconds> (Delay for KILL ON)
          # enforce_time: integer() | nil,
          # # SET KILL <mode>
          # kill: :on | :quick | :immed | :off | nil,
          # # SET SECURE ON/OFF
          # secure: boolean(),

          # # Interaction
          # # SET EMAILMEMOS <mode>
          # email_memos: :on | :off | :only | nil,
          # # SET MSG ON/OFF (true=PRIVMSG, false=NOTICE)
          # msg: boolean(),
          # # SET NOGREET ON/OFF
          # no_greet: boolean(),
          # # SET QUIETCHG ON/OFF
          # quiet_chg: boolean(),

          # # Permissions & Grouping
          # # SET NEVEROP ON/OFF
          # never_op: boolean(),
          # # SET NEVERGROUP ON/OFF
          # never_group: boolean(),

          # # Authentication
          # # SET PUBKEY <key> (SASL)
          # pubkey: String.t() | nil
        }

  @doc """
  Create a new settings struct with common default values.
  """
  @spec new() :: t()
  def new do
    config_settings = get_config_settings()

    %__MODULE__{
      # # User Information
      # email: nil,
      # url: nil,
      # language: config_settings[:language] || "en",
      # property: %{},
      # display: nil,

      # # Hiding Information
      hide_email: config_settings[:hide_email] || false
      # hide_status: config_settings[:hide_status] || false,
      # hide_usermask: config_settings[:hide_usermask] || false,
      # hide_quit: config_settings[:hide_quit] || false,
      # private: config_settings[:private] || false,

      # # Enforcement
      # enforce: config_settings[:enforce] || true,
      # # Rely on server default if not specified in config
      # enforce_time: config_settings[:enforce_time],
      # # Standard delayed kill often default
      # kill: config_settings[:kill] || :on,
      # secure: config_settings[:secure] || false,

      # # Interaction
      # email_memos: config_settings[:email_memos] || :off,
      # # Default to NOTICE if not in config
      # msg: config_settings[:msg] || false,
      # no_greet: config_settings[:no_greet] || false,
      # quiet_chg: config_settings[:quiet_chg] || false,

      # # Permissions & Grouping
      # never_op: config_settings[:never_op] || false,
      # never_group: config_settings[:never_group] || false,

      # # Authentication
      # pubkey: nil
    }
  end

  @doc """
  Update settings struct with new attributes.
  Accepts a map or a keyword list.
  """
  @spec update(t(), map() | keyword()) :: t()
  def update(settings, attrs) do
    struct!(settings, attrs)
  end

  @spec get_config_settings() :: keyword()
  defp get_config_settings do
    Application.get_env(:elixircd, :services, [])
    |> Keyword.get(:nickserv, [])
    |> Keyword.get(:settings, [])
  end
end
