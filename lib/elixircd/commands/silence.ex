defmodule ElixIRCd.Commands.Silence do
  @moduledoc """
  This module defines the SILENCE command.

  SILENCE allows users to maintain a list of masks to block messages from.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [valid_mask_format?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserSilences
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @max_silence_entries 15

  @impl true
  def handle(%{registered: false} = user, %{command: "SILENCE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "SILENCE", params: [], trailing: nil}) do
    show_silence_list(user)
  end

  @impl true
  def handle(user, %{command: "SILENCE", params: [mask | _]}) when mask != "" do
    handle_silence_mask(mask, user)
  end

  @impl true
  def handle(user, %{command: "SILENCE", params: [], trailing: mask}) when mask != "" do
    handle_silence_mask(mask, user)
  end

  @impl true
  def handle(user, %{command: "SILENCE"}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "SILENCE"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec show_silence_list(User.t()) :: :ok
  defp show_silence_list(user) do
    silence_entries = UserSilences.get_by_user_pid(user.pid)

    Enum.each(silence_entries, fn entry ->
      Message.build(%{
        prefix: :server,
        command: :rpl_silence_list,
        params: [user.nick, entry.mask],
        trailing: nil
      })
      |> Dispatcher.broadcast(user)
    end)

    Message.build(%{
      prefix: :server,
      command: :rpl_endofsilence,
      params: [user.nick],
      trailing: "End of silence list"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec handle_silence_mask(String.t(), User.t()) :: :ok
  defp handle_silence_mask("+" <> mask, user) do
    case mask do
      "" -> show_silence_list(user)
      _ -> add_silence_mask(mask, user)
    end
  end

  defp handle_silence_mask("-" <> mask, user) do
    case mask do
      "" -> show_silence_list(user)
      _ -> remove_silence_mask(mask, user)
    end
  end

  defp handle_silence_mask(mask, user) do
    add_silence_mask(mask, user)
  end

  @spec add_silence_mask(String.t(), User.t()) :: :ok
  defp add_silence_mask(mask, user) do
    if valid_mask_format?(mask) do
      silence_entries = UserSilences.get_by_user_pid(user.pid)

      cond do
        length(silence_entries) >= @max_silence_entries ->
          Message.build(%{
            prefix: :server,
            command: :err_silencelistfull,
            params: [user.nick],
            trailing: "Silence list is full"
          })
          |> Dispatcher.broadcast(user)

        Enum.any?(silence_entries, fn entry -> entry.mask == mask end) ->
          show_silence_list(user)

        true ->
          UserSilences.create(%{user_pid: user.pid, mask: mask})
          show_silence_list(user)
      end
    else
      Message.build(%{
        prefix: :server,
        command: :err_badchanmask,
        params: [user.nick, mask],
        trailing: "Invalid silence mask"
      })
      |> Dispatcher.broadcast(user)
    end
  end

  @spec remove_silence_mask(String.t(), User.t()) :: :ok
  defp remove_silence_mask(mask, user) do
    case UserSilences.get_by_user_pid_and_mask(user.pid, mask) do
      {:ok, user_silence} ->
        UserSilences.delete(user_silence)
        show_silence_list(user)

      {:error, :user_silence_not_found} ->
        show_silence_list(user)
    end
  end
end
