defmodule ElixIRCd.Services.Nickserv do
  @moduledoc """
  Module for handling incoming NickServ commands.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]

  alias ElixIRCd.Services.Nickserv
  alias ElixIRCd.Tables.User

  @service_commands %{
    "HELP" => Nickserv.Help,
    "REGISTER" => Nickserv.Register,
    "VERIFY" => Nickserv.Verify,
    "IDENTIFY" => Nickserv.Identify,
    "LOGOUT" => Nickserv.Logout,
    "GHOST" => Nickserv.Ghost,
    "REGAIN" => Nickserv.Regain,
    "RELEASE" => Nickserv.Release,
    "DROP" => Nickserv.Drop,
    "INFO" => Nickserv.Info,
    "SET" => Nickserv.Set
  }

  @impl true
  def handle(user, [service_command | rest_commands]) do
    normalized_service_command = String.upcase(service_command)

    case Map.fetch(@service_commands, normalized_service_command) do
      {:ok, command_module} -> command_module.handle(user, [normalized_service_command | rest_commands])
      :error -> unknown_command_message(user, service_command)
    end
  end

  def handle(user, []) do
    notify(user, [
      "NickServ allows you to register and manage your nickname.",
      "For help on using NickServ, type \x02/msg NickServ HELP\x02"
    ])
  end

  @spec unknown_command_message(User.t(), String.t()) :: :ok
  defp unknown_command_message(user, service_command) do
    notify(user, [
      "Unknown command: \x02#{service_command}\x02",
      "For help on using NickServ, type \x02/msg NickServ HELP\x02"
    ])
  end
end
