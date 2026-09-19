defmodule ElixIRCd.Utils.Nickserv do
  @moduledoc """
  Utility functions for NickServ service.
  """

  import ElixIRCd.Utils.Protocol, only: [chunk_message_text: 2, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Service
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Monitor
  alias ElixIRCd.Utils.Nickserv.Translation

  @doc "Returns whether an email-change verification request is still valid."
  @spec pending_email_active?(RegisteredNick.t(), DateTime.t()) :: boolean()
  def pending_email_active?(registered_nick, now \\ DateTime.utc_now())

  def pending_email_active?(
        %RegisteredNick{
          pending_email: pending_email,
          pending_email_verify_code: verify_code,
          pending_email_requested_at: %DateTime{} = requested_at
        },
        now
      )
      when is_binary(pending_email) and is_binary(verify_code) do
    ttl = Application.fetch_env!(:elixircd, :services)[:nickserv][:email_verification_ttl_seconds]
    DateTime.compare(DateTime.add(requested_at, ttl, :second), now) == :gt
  end

  def pending_email_active?(_registered_nick, _now), do: false

  @doc """
  Sends NickServ notices to a user.
  """
  @spec notify(User.t(), String.t() | [String.t()]) :: :ok
  def notify(user, message) when is_binary(message) do
    send_notice(user, message)
  end

  def notify(user, messages) when is_list(messages) do
    Enum.each(messages, fn message -> send_notice(user, message) end)
    :ok
  end

  @doc "Sends a NickServ notice without passing user-controlled text through translation."
  @spec notify_literal(User.t(), String.t() | [String.t()]) :: :ok
  def notify_literal(user, message) when is_binary(message), do: send_notice(user, message, false)

  def notify_literal(user, messages) when is_list(messages) do
    Enum.each(messages, fn message -> send_notice(user, message, false) end)
    :ok
  end

  @doc """
  Returns the canonical account settings for an identified user, or `nil` when
  the session is not identified or the account no longer exists.
  """
  @spec account_settings(User.t()) :: map() | nil
  def account_settings(%User{identified_as: account_name}) when is_binary(account_name) do
    case RegisteredNicks.get_by_nickname(account_name) do
      {:ok, registered_nick} -> registered_nick.settings
      {:error, :registered_nick_not_found} -> nil
    end
  end

  def account_settings(%User{}), do: nil

  @doc """
  Returns whether an account setting is explicitly enabled.
  """
  @spec account_setting?(String.t() | nil, atom()) :: boolean()
  def account_setting?(nil, _setting), do: false

  def account_setting?(account_name, setting) when is_binary(account_name) do
    case RegisteredNicks.get_by_nickname(account_name) do
      {:ok, registered_nick} -> Map.fetch!(registered_nick.settings, setting) == true
      {:error, :registered_nick_not_found} -> false
    end
  end

  @doc """
  Returns a named setting from an account, or the supplied default when the
  account does not exist.
  """
  @spec account_setting(String.t() | nil, atom(), term()) :: term()
  def account_setting(nil, _setting, default), do: default

  def account_setting(account_name, setting, default) when is_binary(account_name) do
    case RegisteredNicks.get_by_nickname(account_name) do
      {:ok, registered_nick} ->
        Map.fetch!(registered_nick.settings, setting)

      {:error, :registered_nick_not_found} ->
        default
    end
  end

  @doc "Returns whether a connection is protected by TLS or secure WebSocket transport."
  @spec secure_connection?(User.t()) :: boolean()
  def secure_connection?(%User{transport: transport}), do: transport in [:tls, :wss]

  @doc "Returns whether password authentication for an account requires a secure connection."
  @spec account_requires_secure_connection?(String.t() | nil) :: boolean()
  def account_requires_secure_connection?(account_name),
    do: account_setting(account_name, :secure, false) == true

  @doc "Returns the configured display nickname for an account."
  @spec account_display_name(RegisteredNick.t()) :: String.t()
  def account_display_name(registered_nick) do
    Map.get(registered_nick.settings, :display) || registered_nick.account_name
  end

  @doc """
  Formats the email required format for a NickServ command.
  """
  @spec email_required_format(boolean()) :: String.t()
  def email_required_format(email_required?) do
    if email_required?, do: "<email-address>", else: "[email-address]"
  end

  @doc """
  Resolves a nickname or registered nick to its canonical account record.
  """
  @spec get_account_nick(String.t() | RegisteredNick.t()) ::
          {:ok, RegisteredNick.t()} | {:error, :registered_nick_not_found}
  def get_account_nick(%RegisteredNick{} = registered_nick) do
    RegisteredNicks.get_by_nickname(registered_nick.account_name)
  end

  def get_account_nick(nickname) when is_binary(nickname) do
    with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(nickname) do
      get_account_nick(registered_nick)
    end
  end

  @doc """
  Returns true when the nickname belongs to the provided canonical account.
  """
  @spec belongs_to_account?(RegisteredNick.t(), String.t() | nil) :: boolean()
  def belongs_to_account?(_registered_nick, nil), do: false

  def belongs_to_account?(registered_nick, account_name) do
    registered_nick.account_name_key == CaseMapping.normalize(account_name)
  end

  @doc """
  Returns true when the nickname is grouped under another account.
  """
  @spec grouped?(RegisteredNick.t()) :: boolean()
  def grouped?(registered_nick) do
    registered_nick.nickname_key != registered_nick.account_name_key
  end

  @doc """
  Synchronizes +r with ownership of the current registered nickname, including grouped aliases.
  Account authentication alone does not make an unrelated nickname registered.
  """
  @spec sync_registered_mode(User.t()) :: User.t()
  def sync_registered_mode(user) do
    registered =
      with nick when is_binary(nick) <- user.nick,
           {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(nick) do
        belongs_to_account?(registered_nick, user.identified_as)
      else
        _ -> false
      end

    modes = if registered, do: Enum.uniq(user.modes ++ [:r]), else: List.delete(user.modes, :r)

    if modes == user.modes do
      user
    else
      updated_user = Users.update(user, %{modes: modes})

      if user.registered do
        %Message{command: "MODE", params: [user.nick, if(registered, do: "+r", else: "-r")]}
        |> Dispatcher.broadcast(:server, updated_user)
      end

      updated_user
    end
  end

  @doc """
  Logs out all users identified to the given account: clears session, removes +r and sends ACCOUNT *.
  """
  @spec logout_account_users(String.t()) :: :ok
  def logout_account_users(account_name) do
    Users.get_by_identified_as(account_name)
    |> Enum.each(fn target_user ->
      new_modes = List.delete(target_user.modes, :r)

      updated_target_user =
        Users.update(target_user, %{identified_as: nil, sasl_authenticated: false, modes: new_modes})

      %Message{command: "MODE", params: [updated_target_user.nick, "-r"]}
      |> Dispatcher.broadcast(:server, updated_target_user)

      notify_account_logout(updated_target_user)
    end)
  end

  @doc """
  Broadcasts an ACCOUNT message only to recipients with the `account-notify` capability, including self.
  """
  @spec notify_account_change(User.t(), String.t()) :: :ok
  def notify_account_change(user, account) do
    broadcast_account_message(user, account)
  end

  @doc """
  Broadcasts ACCOUNT * only to recipients with the `account-notify` capability, including self.
  """
  @spec notify_account_logout(User.t()) :: :ok
  def notify_account_logout(user) do
    broadcast_account_message(user, "*")
  end

  @doc """
  Removes persisted channel ownership and successor references for an account.
  """
  @spec cleanup_channel_registrations(String.t()) :: :ok
  def cleanup_channel_registrations(account_name) do
    RegisteredChannels.get_by_successor(account_name)
    |> Enum.each(fn channel ->
      RegisteredChannels.update(channel, %{successor: nil})
    end)

    RegisteredChannels.get_by_founder(account_name)
    |> Enum.each(&RegisteredChannels.delete/1)

    :ok
  end

  @spec broadcast_account_message(User.t(), String.t()) :: :ok
  defp broadcast_account_message(user, account) do
    watchers = Monitor.notification_watchers(user, "account-notify", true)

    if watchers != [] do
      %Message{command: "ACCOUNT", params: [account]}
      |> Dispatcher.broadcast(user, watchers)
    end

    :ok
  end

  @spec send_notice(User.t(), String.t()) :: :ok
  defp send_notice(user, message), do: send_notice(user, message, true)

  @spec send_notice(User.t(), String.t(), boolean()) :: :ok
  defp send_notice(user, message, translate?) do
    settings = account_settings(user) || %{}
    command = if Map.get(settings, :msg) == true, do: "PRIVMSG", else: "NOTICE"
    language = Map.get(settings, :language, "en")
    translated_message = if translate?, do: Translation.translate(message, language), else: message

    messages =
      %Message{
        prefix: Service.mask(:nickserv),
        command: command,
        params: [user_reply(user)]
      }
      |> chunk_message_text(translated_message)
      |> Enum.map(&%{&1 | prefix: nil})

    payload =
      case messages do
        [message] -> message
        messages -> messages
      end

    Dispatcher.broadcast(payload, :nickserv, user)
  end
end
