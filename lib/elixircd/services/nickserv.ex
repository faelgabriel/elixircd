defmodule ElixIRCd.Services.Nickserv do
  @moduledoc """
  Module for handling incoming NickServ commands.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [send_notice: 2]

  alias ElixIRCd.Services.Nickserv
  alias ElixIRCd.Tables.User

  @service_commands %{
    "HELP" => Nickserv.Help,
    "REGISTER" => Nickserv.Register,
    "VERIFY" => Nickserv.Verify,
    "IDENTIFY" => Nickserv.Identify,
    "GHOST" => Nickserv.Ghost,
    "REGAIN" => Nickserv.Regain,
    "RELEASE" => Nickserv.Release
  }

  @impl true
  # Handles the command to the appropriate service module
  def handle(user, [service_command | _] = command_list) do
    normalized_service_command = String.upcase(service_command)

    case Map.fetch(@service_commands, normalized_service_command) do
      {:ok, command_module} -> command_module.handle(user, command_list)
      :error -> unknown_command_message(user, service_command)
    end
  end

  def handle(user, []) do
    send_notice(user, "NickServ allows you to register and manage your nickname.")
    send_notice(user, "For help on using NickServ, type \x02/msg NickServ HELP\x02")
    :ok
  end

  @spec unknown_command_message(User.t(), String.t()) :: :ok
  defp unknown_command_message(user, service_command) do
    send_notice(user, "Unknown command: \x02#{service_command}\x02")
    send_notice(user, "For help on using NickServ, type \x02/msg NickServ HELP\x02")
    :ok
  end
end
