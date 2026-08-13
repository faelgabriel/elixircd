defmodule ElixIRCd.Utils.Nickserv do
  @moduledoc """
  Utility functions for NickServ service.
  """

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

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
  Logs out all users identified to the given account: clears session, removes +r and sends ACCOUNT *.
  """
  @spec logout_account_users(String.t()) :: :ok
  def logout_account_users(account_name) do
    Users.get_by_identified_as(account_name)
    |> Enum.each(fn target_user ->
      new_modes = List.delete(target_user.modes, "r")

      updated_target_user =
        Users.update(target_user, %{identified_as: nil, sasl_authenticated: false, modes: new_modes})

      %Message{command: "MODE", params: [updated_target_user.nick, "-r"]}
      |> Dispatcher.broadcast(:server, updated_target_user)

      notify_account_logout(updated_target_user)
    end)
  end

  @doc """
  Broadcasts an ACCOUNT message to the user and optionally to watchers with the `account-notify` capability.
  """
  @spec notify_account_change(User.t(), String.t()) :: :ok
  def notify_account_change(user, account) do
    broadcast_account_message(user, account)
  end

  @doc """
  Broadcasts ACCOUNT * to the user and optionally to watchers with the `account-notify` capability.
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
    %Message{command: "ACCOUNT", params: [account]}
    |> Dispatcher.broadcast(user, [user])

    account_notify_supported = Application.get_env(:elixircd, :capabilities)[:account_notify] || false

    if account_notify_supported do
      watchers =
        Users.get_in_shared_channels_with_capability(user, "account-notify", true)
        |> Enum.reject(&(&1.pid == user.pid))

      if watchers != [] do
        %Message{command: "ACCOUNT", params: [account]}
        |> Dispatcher.broadcast(user, watchers)
      end
    end

    :ok
  end

  @spec send_notice(User.t(), String.t()) :: :ok
  defp send_notice(user, message) do
    %Message{command: "NOTICE", params: [user_reply(user)], trailing: message}
    |> Dispatcher.broadcast(:nickserv, user)
  end
end
