defmodule ElixIRCd.Services.Nickserv.Memo do
  @moduledoc "NickServ MEMO command and account inbox operations."

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [get_account_nick: 1, notify: 2, notify_literal: 2]

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Jobs.MemoEmailDelivery
  alias ElixIRCd.Repositories.Memos
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.Memo
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @max_memo_length 400

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, ["MEMO" | _]) do
    notify(user, [
      "You must identify to NickServ before using MEMO.",
      "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify."
    ])
  end

  def handle(user, ["MEMO", "SEND", target_nick | body_parts]), do: send_memo(user, target_nick, body_parts)
  def handle(user, ["MEMO", "LIST"]), do: list_memos(user)
  def handle(user, ["MEMO", "READ", memo_id]), do: read_memo(user, memo_id)
  def handle(user, ["MEMO", "DEL", memo_id]), do: delete_memo(user, memo_id)
  def handle(user, ["MEMO", "DELETE", memo_id]), do: delete_memo(user, memo_id)
  def handle(user, ["MEMO", "CLEAR"]), do: clear_memos(user)

  def handle(user, ["MEMO"]), do: send_memo_help(user)

  def handle(user, ["MEMO", subcommand | rest]) do
    normalized_subcommand = String.upcase(subcommand)

    if normalized_subcommand == subcommand do
      unknown_memo_operation(user)
    else
      handle(user, ["MEMO", normalized_subcommand | rest])
    end
  end

  @spec unknown_memo_operation(User.t()) :: :ok
  defp unknown_memo_operation(user) do
    notify(user, [
      "Unknown MEMO operation.",
      "Syntax: \x02MEMO {SEND|LIST|READ|DEL|CLEAR}\x02"
    ])
  end

  @spec send_memo(User.t(), String.t(), [String.t()]) :: :ok
  defp send_memo(user, target_nick, body_parts) do
    body = Enum.join(body_parts, " ")

    with :ok <- validate_body(body),
         {:ok, recipient_nick} <- RegisteredNicks.get_by_nickname(target_nick),
         {:ok, recipient_account} <- get_account_nick(recipient_nick),
         :ok <- ensure_recipient_can_receive(recipient_account) do
      deliver_memo(user, recipient_account, body)
    else
      {:error, :empty_body} ->
        notify(user, [
          "Insufficient parameters for \x02MEMO SEND\x02.",
          "Syntax: \x02MEMO SEND <nickname> <message>\x02"
        ])

      {:error, :body_too_long} ->
        notify(user, "Memo is too long. The maximum length is #{@max_memo_length} characters.")

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{target_nick}\x02 is not registered.")

      {:error, :recipient_has_no_email} ->
        notify(user, "That account accepts email-only memos but has no email address configured.")
    end
  end

  @spec validate_body(String.t()) :: :ok | {:error, :empty_body | :body_too_long}
  defp validate_body(body) do
    cond do
      not String.valid?(body) -> {:error, :body_too_long}
      String.trim(body) == "" -> {:error, :empty_body}
      String.length(body) > @max_memo_length -> {:error, :body_too_long}
      String.contains?(body, ["\r", "\n", "\x00"]) -> {:error, :body_too_long}
      true -> :ok
    end
  end

  @spec ensure_recipient_can_receive(ElixIRCd.Tables.RegisteredNick.t()) :: :ok | {:error, :recipient_has_no_email}
  defp ensure_recipient_can_receive(recipient_account) do
    mode = recipient_account.settings.email_memos

    if mode == :only and not verified_email?(recipient_account) do
      {:error, :recipient_has_no_email}
    else
      :ok
    end
  end

  @spec deliver_memo(User.t(), ElixIRCd.Tables.RegisteredNick.t(), String.t()) :: :ok
  defp deliver_memo(user, recipient_account, body) do
    mode = recipient_account.settings.email_memos
    email = recipient_account.email
    verified_email = verified_email?(recipient_account)
    store_result = store_memo(user, recipient_account, mode, body)

    handle_delivery_result(user, recipient_account, mode, email, verified_email, body, store_result)
  end

  @spec store_memo(User.t(), ElixIRCd.Tables.RegisteredNick.t(), atom(), String.t()) ::
          {:ok, boolean()} | {:error, :memo_count_limit | :memo_bytes_limit}
  defp store_memo(_user, _recipient_account, :only, _body), do: {:ok, false}

  defp store_memo(user, recipient_account, _mode, body) do
    attrs = %{
      recipient_account: recipient_account.account_name,
      sender_account: user.identified_as,
      body: body
    }

    case Memos.create_with_limits(attrs, memo_limits()) do
      {:ok, _memo} -> {:ok, true}
      error -> error
    end
  end

  @spec handle_delivery_result(
          User.t(),
          ElixIRCd.Tables.RegisteredNick.t(),
          atom(),
          String.t() | nil,
          boolean(),
          String.t(),
          {:ok, boolean()} | {:error, :memo_count_limit | :memo_bytes_limit}
        ) :: :ok
  defp handle_delivery_result(
         user,
         _recipient_account,
         _mode,
         _email,
         _verified_email,
         _body,
         {:error, :memo_count_limit}
       ) do
    notify(user, "The recipient's NickServ memo inbox is full.")
  end

  defp handle_delivery_result(
         user,
         _recipient_account,
         _mode,
         _email,
         _verified_email,
         _body,
         {:error, :memo_bytes_limit}
       ) do
    notify(user, "The recipient's NickServ memo inbox has reached its storage limit.")
  end

  defp handle_delivery_result(user, recipient_account, mode, email, verified_email, body, {:ok, stored?}) do
    maybe_enqueue_email(user, recipient_account, mode, email, verified_email, stored?, body)
    notify(user, confirmation_for(mode, stored?, verified_email))
  end

  @spec maybe_enqueue_email(
          User.t(),
          ElixIRCd.Tables.RegisteredNick.t(),
          atom(),
          String.t() | nil,
          boolean(),
          boolean(),
          String.t()
        ) ::
          :ok
  defp maybe_enqueue_email(user, recipient_account, mode, email, verified_email, stored?, body) do
    if mode in [:on, :only] and verified_email and (mode == :only or stored?) do
      JobQueue.enqueue(
        MemoEmailDelivery,
        %{
          "email" => email,
          "recipient" => recipient_account.account_name,
          "sender" => user.identified_as,
          "body" => body
        },
        max_attempts: 3,
        retry_delay_ms: 30_000
      )
    end

    :ok
  end

  @spec confirmation_for(atom(), boolean(), boolean()) :: String.t()
  defp confirmation_for(:only, _stored?, _verified_email),
    do: "Your memo was forwarded to the recipient's email address."

  defp confirmation_for(:on, true, true), do: "Your memo was stored and queued for email delivery."
  defp confirmation_for(_mode, _stored?, _verified_email), do: "Your memo was delivered to the NickServ inbox."

  @spec verified_email?(ElixIRCd.Tables.RegisteredNick.t()) :: boolean()
  defp verified_email?(%{email: email, verified_at: verified_at}),
    do: is_binary(email) and not is_nil(verified_at)

  @spec memo_limits() :: keyword()
  defp memo_limits do
    nickserv = Application.fetch_env!(:elixircd, :services)[:nickserv]
    [max_count: nickserv[:max_memos_per_account], max_bytes: nickserv[:max_memo_bytes_per_account]]
  end

  @spec list_memos(User.t()) :: :ok
  defp list_memos(user) do
    memos = Memos.get_by_recipient(user.identified_as)

    if memos == [] do
      notify(user, "Your NickServ memo inbox is empty.")
    else
      notify_memo_list(user, memos)
    end
  end

  @spec notify_memo_list(User.t(), [Memo.t()]) :: :ok
  defp notify_memo_list(user, memos) do
    notify(user, "NickServ memos for \x02#{user.identified_as}\x02:")

    Enum.each(memos, fn memo ->
      state = if memo.read_at, do: "read", else: "unread"
      notify(user, "  #{memo.id} #{state} from #{memo.sender_account} (#{format_datetime(memo.created_at)})")
    end)

    notify(user, "End of memo list.")
  end

  @spec read_memo(User.t(), String.t()) :: :ok
  defp read_memo(user, memo_id) do
    case owned_memo(user, memo_id) do
      {:ok, memo} ->
        memo = if memo.read_at, do: memo, else: Memos.update(memo, %{read_at: DateTime.utc_now()})
        notify(user, "Memo #{memo.id} from #{memo.sender_account} (#{format_datetime(memo.created_at)}):")
        notify_literal(user, memo.body)

      :error ->
        notify(user, "Memo \x02#{memo_id}\x02 was not found in your inbox.")
    end
  end

  @spec delete_memo(User.t(), String.t()) :: :ok
  defp delete_memo(user, memo_id) do
    case owned_memo(user, memo_id) do
      {:ok, memo} ->
        Memos.delete(memo)
        notify(user, "Memo \x02#{memo_id}\x02 has been deleted.")

      :error ->
        notify(user, "Memo \x02#{memo_id}\x02 was not found in your inbox.")
    end
  end

  @spec clear_memos(User.t()) :: :ok
  defp clear_memos(user) do
    count = Memos.delete_by_recipient(user.identified_as)
    notify(user, "Deleted #{count} #{if count == 1, do: "memo", else: "memos"} from your inbox.")
  end

  @spec owned_memo(User.t(), String.t()) :: {:ok, Memo.t()} | :error
  defp owned_memo(user, memo_id) do
    account_key = CaseMapping.normalize(user.identified_as)

    case Memos.get_by_id(memo_id) do
      {:ok, %{recipient_account_key: ^account_key} = memo} ->
        {:ok, memo}

      _ ->
        :error
    end
  end

  @spec send_memo_help(User.t()) :: :ok
  defp send_memo_help(user) do
    notify(user, [
      "NickServ MEMO help:",
      "\x02MEMO SEND <nickname> <message>\x02 - Send a memo to a registered account.",
      "\x02MEMO LIST\x02 - List your stored memos.",
      "\x02MEMO READ <id>\x02 - Read and mark a memo as read.",
      "\x02MEMO DEL <id>\x02 - Delete one memo.",
      "\x02MEMO CLEAR\x02 - Delete all stored memos."
    ])
  end

  @spec format_datetime(DateTime.t()) :: String.t()
  defp format_datetime(datetime), do: DateTime.to_iso8601(datetime) |> String.replace("T", " ")
end
