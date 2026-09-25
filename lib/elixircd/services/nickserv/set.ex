defmodule ElixIRCd.Services.Nickserv.Set do
  @moduledoc """
  This module defines the NickServ SET command.

  SET changes account-level nickname preferences. Every successful change is
  written to the canonical registered nickname, so grouped nicknames share the
  same settings.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [notify: 2, pending_email_active?: 1]
  import ElixIRCd.Utils.Validation, only: [validate_email: 1]

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Jobs.VerificationEmailDelivery
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Ecdsa

  @boolean_options [
    {"HIDEMAIL", :hide_email, "Hide your email address in INFO displays"},
    {"HIDESTATUS", :hide_status, "Hide online status in INFO displays"},
    {"HIDEUSERMASK", :hide_usermask, "Hide your registration mask in INFO displays"},
    {"HIDEQUIT", :hide_quit, "Hide your last quit information"},
    {"ENFORCE", :enforce, "Enforce ownership of your registered nickname"},
    {"NEVERGROUP", :never_group, "Prevent grouping another nickname into your account"},
    {"NEVEROP", :never_op, "Prevent ChanServ from automatically giving you operator status"},
    {"NOGREET", :no_greet, "Suppress the NickServ greeting after identification"},
    {"PRIVATE", :private, "Hide your nickname from NickServ LIST"},
    {"QUIETCHG", :quiet_chg, "Suppress ChanServ mode and flag changes for your session"},
    {"SECURE", :secure, "Require a secure connection for account authentication"},
    {"MSG", :msg, "Use PRIVMSG instead of NOTICE for NickServ messages"}
  ]

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["SET", subcommand | rest_params]) do
    if user.identified_as do
      dispatch_setting(user, String.upcase(subcommand), rest_params)
    else
      notify(user, [
        "You must identify to NickServ before using the SET command.",
        "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify."
      ])
    end
  end

  def handle(user, ["SET"]) do
    notify(user, [
      "Insufficient parameters for \x02SET\x02.",
      "Syntax: \x02SET <option> <parameters>\x02"
    ])

    send_available_settings(user)
  end

  @spec dispatch_setting(User.t(), String.t(), [String.t()]) :: :ok
  defp dispatch_setting(user, "EMAIL", params), do: handle_email(user, params)

  defp dispatch_setting(user, "EMAILMEMOS", params),
    do: handle_enum(user, "EMAILMEMOS", :email_memos, [:on, :off, :only], params)

  defp dispatch_setting(user, "HIDEMAIL", params), do: handle_hidemail(user, params)
  defp dispatch_setting(user, "ENFORCE", params), do: handle_boolean(user, "ENFORCE", :enforce, params)
  defp dispatch_setting(user, "ENFORCETIME", params), do: handle_enforce_time(user, params)
  defp dispatch_setting(user, "LANGUAGE", params), do: handle_language(user, params)
  defp dispatch_setting(user, "KILL", params), do: handle_enum(user, "KILL", :kill, [:on, :quick, :immed, :off], params)
  defp dispatch_setting(user, "PROPERTY", params), do: handle_property(user, params)
  defp dispatch_setting(user, "PUBKEY", params), do: handle_pubkey(user, params)
  defp dispatch_setting(user, "URL", params), do: handle_url(user, params)
  defp dispatch_setting(user, "DISPLAY", params), do: handle_display(user, params)

  defp dispatch_setting(user, option, params) do
    case Enum.find(@boolean_options, fn {name, _field, _description} -> name == option end) do
      {^option, field, _description} -> handle_boolean(user, option, field, params)
      nil -> unknown_subcommand_message(user, option)
    end
  end

  @spec handle_hidemail(User.t(), [String.t()]) :: :ok
  defp handle_hidemail(user, [value | _rest_params]) do
    case String.upcase(value) do
      "ON" -> update_hidemail_setting(user, true)
      "OFF" -> update_hidemail_setting(user, false)
      _ -> invalid_boolean(user, "HIDEMAIL")
    end
  end

  defp handle_hidemail(user, []), do: insufficient_option_parameters(user, "HIDEMAIL", "{ON|OFF}")

  @spec update_hidemail_setting(User.t(), boolean()) :: :ok
  defp update_hidemail_setting(user, hide_email) do
    case update_settings(user, %{hide_email: hide_email}) do
      {:ok, _account} ->
        message =
          if hide_email,
            do: "Your email address will now be hidden from \x02INFO\x02 displays.",
            else: "Your email address will now be shown in \x02INFO\x02 displays."

        notify(user, message)

      :error ->
        notify_settings_error(user)
    end
  end

  @spec handle_boolean(User.t(), String.t(), atom(), [String.t()]) :: :ok
  defp handle_boolean(user, option, field, [value | _rest_params]) do
    case String.upcase(value) do
      "ON" -> update_boolean_setting(user, option, field, true)
      "OFF" -> update_boolean_setting(user, option, field, false)
      _ -> invalid_boolean(user, option)
    end
  end

  defp handle_boolean(user, option, _field, []) do
    insufficient_option_parameters(user, option, "{ON|OFF}")
  end

  @spec update_boolean_setting(User.t(), String.t(), atom(), boolean()) :: :ok
  defp update_boolean_setting(user, option, field, value) do
    case update_settings(user, %{field => value}) do
      {:ok, _account} -> maybe_notify_change(user, option, if(value, do: "ON", else: "OFF"))
      :error -> notify_settings_error(user)
    end
  end

  @spec handle_enum(User.t(), String.t(), atom(), [atom()], [String.t()]) :: :ok
  defp handle_enum(user, option, field, choices, [value | _rest_params]) do
    normalized = String.downcase(value)

    case Enum.find(choices, &(Atom.to_string(&1) == normalized)) do
      nil ->
        notify(user, [
          "Invalid parameter for \x02#{option}\x02.",
          "Syntax: \x02SET #{option} {#{Enum.map_join(choices, "|", &(&1 |> Atom.to_string() |> String.upcase()))}}\x02"
        ])

      choice ->
        case update_settings(user, %{field => choice}) do
          {:ok, _account} -> maybe_notify_change(user, option, String.upcase(normalized))
          :error -> notify_settings_error(user)
        end
    end
  end

  defp handle_enum(user, option, _field, choices, []) do
    syntax = Enum.map_join(choices, "|", &(&1 |> Atom.to_string() |> String.upcase()))
    insufficient_option_parameters(user, option, "{#{syntax}}")
  end

  @spec handle_enforce_time(User.t(), [String.t()]) :: :ok
  defp handle_enforce_time(user, [value | _rest_params]) do
    max_enforce_time = Application.fetch_env!(:elixircd, :services)[:nickserv][:max_enforce_time]

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 and seconds <= max_enforce_time ->
        case update_settings(user, %{enforce_time: seconds}) do
          {:ok, _account} -> maybe_notify_change(user, "ENFORCETIME", Integer.to_string(seconds))
          :error -> notify_settings_error(user)
        end

      _ ->
        notify(user, [
          "Invalid parameter for \x02ENFORCETIME\x02.",
          "Syntax: \x02SET ENFORCETIME <seconds>\x02"
        ])
    end
  end

  defp handle_enforce_time(user, []) do
    insufficient_option_parameters(user, "ENFORCETIME", "<seconds>")
  end

  @spec handle_language(User.t(), [String.t()]) :: :ok
  defp handle_language(user, [value | _rest_params]) do
    language = normalize_language(value)

    if language do
      case update_settings(user, %{language: language}) do
        {:ok, _account} -> maybe_notify_change(user, "LANGUAGE", language)
        :error -> notify_settings_error(user)
      end
    else
      notify(user, [
        "Invalid language. Supported languages: \x02en\x02, \x02pt-BR\x02.",
        "Syntax: \x02SET LANGUAGE <language>\x02"
      ])
    end
  end

  defp handle_language(user, []) do
    insufficient_option_parameters(user, "LANGUAGE", "<language>")
  end

  @spec handle_email(User.t(), [String.t()]) :: :ok
  defp handle_email(user, [value | _rest_params]) do
    email = String.trim(value)
    email_required? = Application.fetch_env!(:elixircd, :services)[:nickserv][:email_required]

    cond do
      String.upcase(email) == "OFF" and email_required? ->
        notify(user, "This server requires an email address for registered nicknames.")

      String.upcase(email) == "OFF" ->
        update_email(user, nil)

      validate_email(email) == :ok ->
        update_email(user, String.downcase(email))

      true ->
        notify(user, [
          "Invalid email address. Please provide a valid email address.",
          "Syntax: \x02SET EMAIL <email-address>\x02 or \x02SET EMAIL OFF\x02"
        ])
    end
  end

  defp handle_email(user, []) do
    insufficient_option_parameters(user, "EMAIL", "<email-address> or OFF")
  end

  @spec update_email(User.t(), String.t() | nil) :: :ok
  defp update_email(user, email) do
    with {:ok, account} <- get_account(user),
         :ok <- ensure_email_changed(account, email) do
      verify_code = if email, do: random_verification_code(), else: nil

      attrs =
        cond do
          is_nil(email) ->
            %{
              email: nil,
              verify_code: nil,
              pending_email: nil,
              pending_email_verify_code: nil,
              pending_email_requested_at: nil
            }

          is_nil(account.verified_at) ->
            %{
              email: email,
              verify_code: verify_code,
              pending_email: nil,
              pending_email_verify_code: nil,
              pending_email_requested_at: nil
            }

          true ->
            %{
              pending_email: email,
              pending_email_verify_code: verify_code,
              pending_email_requested_at: DateTime.utc_now()
            }
        end

      updated = RegisteredNicks.update(account, attrs)

      if email do
        JobQueue.enqueue(
          VerificationEmailDelivery,
          %{"email" => email, "nickname" => updated.nickname, "verification_code" => verify_code},
          max_attempts: 3,
          retry_delay_ms: 30_000
        )

        notify(user, [
          if(account.verified_at,
            do: "A verification email has been sent to confirm \x02#{email}\x02.",
            else: "Your email address has been changed to \x02#{email}\x02."
          ),
          "Verify it with \x02/msg NickServ VERIFY #{updated.nickname} <code>\x02."
        ])
      else
        notify(user, "Your email address has been removed from your account.")
      end
    else
      {:error, :same_email} -> notify(user, "That is already the email address on your account.")
      :error -> notify_settings_error(user)
    end
  end

  @spec ensure_email_changed(RegisteredNick.t(), String.t() | nil) :: :ok | {:error, :same_email}
  defp ensure_email_changed(%RegisteredNick{email: email}, email),
    do: {:error, :same_email}

  defp ensure_email_changed(%RegisteredNick{pending_email: pending_email} = account, pending_email)
       when is_binary(pending_email) do
    if pending_email_active?(account), do: {:error, :same_email}, else: :ok
  end

  defp ensure_email_changed(_account, _email), do: :ok

  @spec random_verification_code() :: String.t()
  defp random_verification_code do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  @spec handle_url(User.t(), [String.t()]) :: :ok
  defp handle_url(user, [value | _rest_params]) do
    case String.upcase(value) do
      "OFF" ->
        update_simple_setting(user, :url, nil, "URL")

      _ ->
        case validate_url(value) do
          :ok -> update_simple_setting(user, :url, value, "URL")
          :error -> notify(user, ["Invalid URL.", "Syntax: \x02SET URL <url>\x02 or \x02SET URL OFF\x02"])
        end
    end
  end

  defp handle_url(user, []) do
    insufficient_option_parameters(user, "URL", "<url> or OFF")
  end

  @spec handle_display(User.t(), [String.t()]) :: :ok
  defp handle_display(user, [value | _rest_params]) do
    case String.upcase(value) do
      "OFF" ->
        update_simple_setting(user, :display, nil, "DISPLAY")

      _ ->
        case validate_display(value) do
          :ok ->
            update_display_setting(user, value)

          :error ->
            notify(user, [
              "Invalid nickname for DISPLAY.",
              "Syntax: \x02SET DISPLAY <nickname>\x02 or \x02SET DISPLAY OFF\x02"
            ])
        end
    end
  end

  defp handle_display(user, []) do
    insufficient_option_parameters(user, "DISPLAY", "<nickname> or OFF")
  end

  @spec update_display_setting(User.t(), String.t()) :: :ok
  defp update_display_setting(user, display_nick) do
    case get_account(user) do
      {:ok, account} ->
        case RegisteredNicks.get_by_nickname(display_nick) do
          {:ok, grouped_nick} when grouped_nick.account_name_key == account.account_name_key ->
            update_simple_setting(user, :display, grouped_nick.nickname, "DISPLAY")

          _ ->
            notify(user, [
              "DISPLAY must be a nickname already grouped into your account.",
              "Syntax: \x02SET DISPLAY <nickname>\x02 or \x02SET DISPLAY OFF\x02"
            ])
        end

      :error ->
        notify_settings_error(user)
    end
  end

  @spec handle_property(User.t(), [String.t()]) :: :ok
  defp handle_property(user, ["LIST" | _rest_params]) do
    list_properties(user)
  end

  defp handle_property(user, [command | rest_params]) when is_binary(command) do
    if String.upcase(command) == "LIST" do
      list_properties(user)
    else
      handle_property_arguments(user, [command | rest_params])
    end
  end

  defp handle_property(user, []) do
    insufficient_option_parameters(user, "PROPERTY", "<name> [value|OFF]")
  end

  @spec handle_property_arguments(User.t(), [String.t()]) :: :ok
  defp handle_property_arguments(user, [key, value | rest_params]) do
    if String.upcase(value) == "OFF" and rest_params == [] do
      update_property(user, key, nil)
    else
      update_property(user, key, Enum.join([value | rest_params], " "))
    end
  end

  defp handle_property_arguments(user, [key]) do
    case get_account(user) do
      {:ok, account} ->
        properties = account.settings.property
        notify(user, "PROPERTY #{key} = #{Map.get(properties, key, "(not set)")}")

      :error ->
        notify_settings_error(user)
    end
  end

  @spec list_properties(User.t()) :: :ok
  defp list_properties(user) do
    case get_account(user) do
      {:ok, account} ->
        properties = account.settings.property
        notify_properties(user, properties)

      :error ->
        notify_settings_error(user)
    end
  end

  @spec notify_properties(User.t(), map()) :: :ok
  defp notify_properties(user, properties) do
    if map_size(properties) == 0 do
      notify(user, "No custom properties are set.")
    else
      properties
      |> Enum.sort()
      |> Enum.each(fn {key, value} -> notify(user, "PROPERTY #{key} = #{value}") end)
    end
  end

  @spec update_property(User.t(), String.t(), String.t() | nil) :: :ok
  defp update_property(user, key, value) do
    if valid_property_key?(key) and (is_nil(value) or valid_property_value?(value)) do
      update_property_for_account(user, key, value)
    else
      notify(user, "Invalid PROPERTY name or value. Names must be 1-64 characters and values 1-300 characters.")
    end
  end

  @spec update_property_for_account(User.t(), String.t(), String.t() | nil) :: :ok
  defp update_property_for_account(user, key, value) do
    case get_account(user) do
      {:ok, account} ->
        {:ok, account} = RegisteredNicks.get_by_nickname_for_update(account.nickname)
        properties = account.settings.property
        property = update_property_value(properties, key, value)
        persist_property(user, account, properties, property, key, value)

      :error ->
        notify_settings_error(user)
    end
  end

  @spec persist_property(User.t(), RegisteredNick.t(), map(), map(), String.t(), String.t() | nil) :: :ok
  defp persist_property(user, account, old_properties, new_properties, key, value) do
    if valid_property_quota?(old_properties, new_properties) do
      RegisteredNicks.update(account, %{settings: Settings.update(account.settings, %{property: new_properties})})
      maybe_notify_change(user, "PROPERTY", property_change_label(key, value))
    else
      notify(user, "This account has reached its custom PROPERTY quota.")
    end
  end

  @spec property_change_label(String.t(), String.t() | nil) :: String.t()
  defp property_change_label(key, nil), do: "#{key} removed"
  defp property_change_label(key, _value), do: "#{key} updated"

  @spec update_property_value(map(), String.t(), String.t() | nil) :: map()
  defp update_property_value(properties, key, nil), do: Map.delete(properties, key)
  defp update_property_value(properties, key, value), do: Map.put(properties, key, value)

  @spec handle_pubkey(User.t(), [String.t()]) :: :ok
  defp handle_pubkey(user, [value | _rest_params]) do
    case String.upcase(value) do
      "OFF" ->
        update_simple_setting(user, :pubkey, nil, "PUBKEY")

      _ ->
        case decode_public_key(value) do
          {:ok, _decoded} ->
            update_simple_setting(user, :pubkey, value, "PUBKEY")

          _ ->
            notify(user, [
              "Invalid public key. Supply a base64-encoded compressed P-256 key or OFF.",
              "Syntax: \x02SET PUBKEY <base64-key>\x02 or \x02SET PUBKEY OFF\x02"
            ])
        end
    end
  end

  defp handle_pubkey(user, []) do
    case get_account(user) do
      {:ok, account} ->
        case Map.get(account.settings, :pubkey) do
          nil -> notify(user, "No public key is configured.")
          pubkey -> notify(user, "A public key is configured: #{pubkey}")
        end

      :error ->
        notify_settings_error(user)
    end
  end

  @spec update_simple_setting(User.t(), atom(), term(), String.t()) :: :ok
  defp update_simple_setting(user, field, value, option) do
    case update_settings(user, %{field => value}) do
      {:ok, _account} -> maybe_notify_change(user, option, if(is_nil(value), do: "OFF", else: to_string(value)))
      :error -> notify_settings_error(user)
    end
  end

  @spec update_settings(User.t(), map()) :: {:ok, RegisteredNick.t()} | :error
  defp update_settings(user, attrs) do
    case get_account(user) do
      {:ok, account} ->
        {:ok, RegisteredNicks.update(account, %{settings: Settings.update(account.settings, attrs)})}

      :error ->
        :error
    end
  end

  @spec get_account(User.t()) :: {:ok, RegisteredNick.t()} | :error
  defp get_account(user) do
    case RegisteredNicks.get_by_nickname(user.identified_as) do
      {:ok, account} ->
        {:ok, account}

      {:error, _error_reason} ->
        Logger.error("NickServ settings update failed", event: "service.settings_failed")
        :error
    end
  end

  @spec maybe_notify_change(User.t(), String.t(), String.t()) :: :ok
  defp maybe_notify_change(user, option, value) do
    notify(user, "Your \x02#{option}\x02 setting is now \x02#{value}\x02.")
  end

  @spec normalize_language(String.t()) :: String.t() | nil
  defp normalize_language(language) do
    case String.downcase(language) do
      "en" -> "en"
      "pt-br" -> "pt-BR"
      _ -> nil
    end
  end

  @spec validate_url(String.t()) :: :ok | :error
  defp validate_url(value) do
    with {:ok, uri} <- URI.new(value),
         true <- uri.scheme in ["http", "https"],
         true <- is_binary(uri.host),
         true <- uri.userinfo == nil,
         true <- uri.fragment == nil,
         true <- String.valid?(value) do
      :ok
    else
      _ -> :error
    end
  end

  @spec validate_display(String.t()) :: :ok | :error
  defp validate_display(value) do
    max_length = Application.fetch_env!(:elixircd, :user)[:max_nick_length]
    pattern = ~r/\A[a-zA-Z\`|\^_{}\[\]\\][a-zA-Z\d\`|\^_\-{}\[\]\\]*\z/

    if String.length(value) <= max_length and Regex.match?(pattern, value), do: :ok, else: :error
  end

  @spec decode_public_key(String.t()) :: {:ok, binary()} | :error
  defp decode_public_key(value) do
    case Base.decode64(value, padding: false) do
      {:ok, <<prefix, _x::binary-size(32)>> = public_key} when prefix in [2, 3] ->
        if valid_public_key?(public_key), do: {:ok, public_key}, else: :error

      _ ->
        :error
    end
  end

  @spec valid_public_key?(binary()) :: boolean()
  defp valid_public_key?(public_key), do: Ecdsa.valid_compressed_p256_public_key?(public_key)

  @spec valid_property_key?(String.t()) :: boolean()
  defp valid_property_key?(key),
    do: byte_size(key) in 1..64 and String.valid?(key) and not String.contains?(key, [" ", "\r", "\n", "\x00"])

  @spec valid_property_value?(String.t()) :: boolean()
  defp valid_property_value?(value),
    do: String.length(value) in 1..300 and String.valid?(value) and not String.contains?(value, ["\r", "\n", "\x00"])

  @spec valid_property_quota?(map(), map()) :: boolean()
  defp valid_property_quota?(old_properties, new_properties) do
    nickserv = Application.fetch_env!(:elixircd, :services)[:nickserv]

    (map_size(new_properties) <= nickserv[:max_properties] and
       property_bytes(new_properties) <= nickserv[:max_property_bytes]) or
      new_properties == old_properties
  end

  @spec property_bytes(map()) :: non_neg_integer()
  defp property_bytes(properties) do
    Enum.reduce(properties, 0, fn {key, value}, total -> total + byte_size(key) + byte_size(value) end)
  end

  @spec insufficient_option_parameters(User.t(), String.t(), String.t()) :: :ok
  defp insufficient_option_parameters(user, option, syntax) do
    notify(user, [
      "Insufficient parameters for \x02#{option}\x02.",
      "Syntax: \x02SET #{option} #{syntax}\x02"
    ])
  end

  @spec invalid_boolean(User.t(), String.t()) :: :ok
  defp invalid_boolean(user, option) do
    notify(user, [
      "Invalid parameter for \x02#{option}\x02.",
      "Syntax: \x02SET #{option} {ON|OFF}\x02"
    ])
  end

  @spec notify_settings_error(User.t()) :: :ok
  defp notify_settings_error(user) do
    notify(user, "An error occurred while updating your NickServ settings.")
  end

  @spec unknown_subcommand_message(User.t(), String.t()) :: :ok
  defp unknown_subcommand_message(user, subcommand) do
    notify(user, "Unknown SET option: \x02#{subcommand}\x02")
    send_available_settings(user)
  end

  @spec send_available_settings(User.t()) :: :ok
  defp send_available_settings(user) do
    options =
      [
        {"EMAIL", "Change your account email address"},
        {"EMAILMEMOS", "Control email delivery for memos"},
        {"ENFORCE", "Enforce ownership of your registered nickname"},
        {"ENFORCETIME", "Set the enforcement grace period"},
        {"LANGUAGE", "Choose the NickServ language"},
        {"KILL", "Choose the action for an enforced nickname"},
        {"PROPERTY", "Manage custom account properties"},
        {"PUBKEY", "Manage your authentication public key"},
        {"URL", "Set your account URL"},
        {"DISPLAY", "Set your preferred display nickname"}
      ] ++ Enum.map(@boolean_options, fn {name, _field, description} -> {name, description} end)

    notify(user, ["Available SET options:"])

    Enum.each(options, fn {name, description} ->
      notify(user, "\x02#{name}\x02 - #{description}")
    end)
  end
end
