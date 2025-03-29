defmodule ElixIRCd.Utils.Nickserv do
  @moduledoc """
  Utility functions for NickServ service.
  """

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User


  @doc """
  Sends a NickServ notice to a user.
  """
  @spec send_notice(User.t(), String.t()) :: :ok
  def send_notice(user, message) do
    Message.build(%{
      prefix: "NickServ!service@#{Application.get_env(:elixircd, :server)[:hostname]}",
      command: "NOTICE",
      params: [user_reply(user)],
      trailing: message
    })
    |> Dispatcher.broadcast(user)
  end

  @doc """
  Validates a nickname's password.
  """
  @spec validate_password(String.t(), String.t()) :: {:ok, RegisteredNick.t()} | {:error, String.t()}
  def validate_password(nickname, password) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
          {:ok, registered_nick}
        else
          {:error, "Invalid password"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Count the number of nicknames registered by the same user.
  """
  @spec count_registered_nicks(String.t()) :: integer()
  def count_registered_nicks(host_ident) do
    RegisteredNicks.get_all()
    |> Enum.count(fn reg_nick -> reg_nick.registered_by == host_ident end)
  end

  @doc """
  Check if user can register more nicknames.
  """
  @spec can_register_more_nicks?(String.t()) :: boolean()
  def can_register_more_nicks?(host_ident) do
    max_nicks = Application.get_env(:elixircd, :services)[:nickserv][:max_nicks_per_user] || 3
    count_registered_nicks(host_ident) < max_nicks
  end

  @doc """
  Update a registered nickname's last seen timestamp.
  """
  @spec update_last_seen(String.t()) :: {:ok, RegisteredNick.t()} | {:error, String.t()}
  def update_last_seen(nickname) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        updated_nick = RegisteredNicks.update(registered_nick, %{last_seen_at: DateTime.utc_now()})
        {:ok, updated_nick}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update a registered nickname's email.
  """
  @spec update_email(String.t(), String.t()) :: {:ok, RegisteredNick.t()} | {:error, String.t()}
  def update_email(nickname, email) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        updated_nick = RegisteredNicks.update(registered_nick, %{email: email})
        {:ok, updated_nick}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update a registered nickname's password.
  """
  @spec update_password(String.t(), String.t()) :: {:ok, RegisteredNick.t()} | {:error, String.t()}
  def update_password(nickname, password) do
    # Hash the new password
    password_hash = Pbkdf2.hash_pwd_salt(password)

    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        updated_nick = RegisteredNicks.update(registered_nick, %{password_hash: password_hash})
        {:ok, updated_nick}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete a registered nickname.
  """
  @spec delete_nickname(String.t()) :: :ok | {:error, String.t()}
  def delete_nickname(nickname) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        RegisteredNicks.delete(registered_nick)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Formats a help message for a NickServ command.
  """
  @spec format_help(String.t(), [String.t()], String.t()) :: String.t()
  def format_help(command, syntax, description) do
    syntax_str = Enum.join(syntax, " or ")
    "#{command} #{syntax_str} - #{description}"
  end

  @doc """
  Gets the general help message for NickServ.
  """
  @spec general_help() :: [String.t()]
  def general_help do
    nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90

    [
      "NickServ allows you to register and manage your nickname.",
      "Nicknames that remain unused for #{nick_expire_days} days may expire.",
      "Available commands:",
      "REGISTER - Register your current nickname",
      "VERIFY   - Verify your registered nickname",
      "IDENTIFY - Identify yourself with a registered nickname",
      "SET      - Set various nickname options",
      "DROP     - Drop a registered nickname",
      "INFO     - Display information about a nickname",
      "HELP     - Display this help message",
      "For more information on a command, type /msg NickServ HELP <command>"
    ]
  end
end
