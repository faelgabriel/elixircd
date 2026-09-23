defmodule ElixIRCd.Tables.RegisteredNick.Settings do
  @moduledoc """
  Module for the RegisteredNick.Settings data structure.

  Stores user-configurable options set via the NickServ SET command.
  """

  defstruct [
    :email_memos,
    :enforce,
    :enforce_time,
    :hide_email,
    :hide_status,
    :hide_usermask,
    :hide_quit,
    :kill,
    :language,
    :msg,
    :never_group,
    :never_op,
    :no_greet,
    :private,
    :property,
    :pubkey,
    :quiet_chg,
    :secure,
    :url,
    :display
  ]

  @fields [
    :email_memos,
    :enforce,
    :enforce_time,
    :hide_email,
    :hide_status,
    :hide_usermask,
    :hide_quit,
    :kill,
    :language,
    :msg,
    :never_group,
    :never_op,
    :no_greet,
    :private,
    :property,
    :pubkey,
    :quiet_chg,
    :secure,
    :url,
    :display
  ]

  @type email_memos() :: :on | :off | :only
  @type kill_mode() :: :on | :quick | :immed | :off

  @type t :: %__MODULE__{
          email_memos: email_memos(),
          enforce: boolean(),
          enforce_time: non_neg_integer(),
          hide_email: boolean(),
          hide_status: boolean(),
          hide_usermask: boolean(),
          hide_quit: boolean(),
          kill: kill_mode(),
          language: String.t(),
          msg: boolean(),
          never_group: boolean(),
          never_op: boolean(),
          no_greet: boolean(),
          private: boolean(),
          property: %{optional(String.t()) => String.t()},
          pubkey: String.t() | nil,
          quiet_chg: boolean(),
          secure: boolean(),
          url: String.t() | nil,
          display: String.t() | nil
        }

  @type t_attrs :: %{
          optional(:email_memos) => email_memos(),
          optional(:enforce) => boolean(),
          optional(:enforce_time) => non_neg_integer(),
          optional(:hide_email) => boolean(),
          optional(:hide_status) => boolean(),
          optional(:hide_usermask) => boolean(),
          optional(:hide_quit) => boolean(),
          optional(:kill) => kill_mode(),
          optional(:language) => String.t(),
          optional(:msg) => boolean(),
          optional(:never_group) => boolean(),
          optional(:never_op) => boolean(),
          optional(:no_greet) => boolean(),
          optional(:private) => boolean(),
          optional(:property) => %{optional(String.t()) => String.t()},
          optional(:pubkey) => String.t() | nil,
          optional(:quiet_chg) => boolean(),
          optional(:secure) => boolean(),
          optional(:url) => String.t() | nil,
          optional(:display) => String.t() | nil
        }

  @doc """
  Create a new settings struct with common default values.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs \\ %{}) do
    config_settings = get_config_settings()

    attrs
    |> Map.put_new(:email_memos, config_settings[:email_memos])
    |> Map.put_new(:enforce, config_settings[:enforce])
    |> Map.put_new(:enforce_time, config_settings[:enforce_time])
    |> Map.put_new(:hide_email, config_settings[:hide_email])
    |> Map.put_new(:hide_status, config_settings[:hide_status])
    |> Map.put_new(:hide_usermask, config_settings[:hide_usermask])
    |> Map.put_new(:hide_quit, config_settings[:hide_quit])
    |> Map.put_new(:kill, config_settings[:kill])
    |> Map.put_new(:language, config_settings[:language])
    |> Map.put_new(:msg, config_settings[:msg])
    |> Map.put_new(:never_group, config_settings[:never_group])
    |> Map.put_new(:never_op, config_settings[:never_op])
    |> Map.put_new(:no_greet, config_settings[:no_greet])
    |> Map.put_new(:private, config_settings[:private])
    |> Map.put_new(:property, config_settings[:property] || %{})
    |> Map.put_new(:pubkey, config_settings[:pubkey])
    |> Map.put_new(:quiet_chg, config_settings[:quiet_chg])
    |> Map.put_new(:secure, config_settings[:secure])
    |> Map.put_new(:url, config_settings[:url])
    |> Map.put_new(:display, config_settings[:display])
    |> then(&struct!(__MODULE__, &1))
  end

  @doc """
  Update settings struct with new attributes.
  """
  @spec update(t(), t_attrs()) :: t()
  def update(settings, attrs) do
    settings
    |> normalize()
    |> struct!(attrs)
  end

  @doc "Completes settings values loaded from older persisted schemas."
  @spec normalize(t() | map() | nil) :: t()
  def normalize(%__MODULE__{} = settings) do
    known_values =
      settings
      |> Map.from_struct()
      |> Map.take(@fields)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    extras = Map.drop(settings, [:__struct__ | @fields])
    Map.merge(new(known_values), extras)
  end

  def normalize(settings) when is_map(settings) do
    settings
    |> Map.take(@fields)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> new()
  end

  def normalize(nil), do: new()

  @spec get_config_settings() :: keyword()
  defp get_config_settings do
    Application.fetch_env!(:elixircd, :services)
    |> Keyword.fetch!(:nickserv)
    |> Keyword.fetch!(:settings)
  end
end
