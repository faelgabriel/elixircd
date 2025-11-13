defmodule ElixIRCd.Commands.Motd do
  @moduledoc """
  This module defines the MOTD command.

  MOTD displays the Message of the Day to the user.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "MOTD"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "MOTD"}) do
    send_motd(user)
  end

  @doc """
  Sends the Message of the Day to the user.
  """
  @spec send_motd(User.t()) :: :ok
  def send_motd(user) do
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]

    %Message{command: :rpl_motdstart, params: [user.nick], trailing: "#{server_hostname} Message of the Day"}
    |> Dispatcher.broadcast(:server, user)

    config_motd_content()
    |> case do
      nil ->
        %Message{command: :err_nomotd, params: [user.nick], trailing: "MOTD is missing"}

      content ->
        content
        |> String.split(~r/\R/, trim: true)
        |> Enum.map(&%Message{command: :rpl_motd, params: [user.nick], trailing: &1})
    end
    |> Dispatcher.broadcast(:server, user)

    %Message{command: :rpl_endofmotd, params: [user.nick], trailing: "End of /MOTD command"}
    |> Dispatcher.broadcast(:server, user)
  end

  # the motd config supports a string or a File.read/1 result
  @spec config_motd_content :: String.t() | nil
  defp config_motd_content do
    Application.get_env(:elixircd, :server)[:motd]
    |> case do
      content when is_binary(content) -> content
      nil -> nil
      {:ok, content} -> content
      {:error, _error} -> nil
    end
  end
end
