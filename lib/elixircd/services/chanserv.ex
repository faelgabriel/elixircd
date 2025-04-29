defmodule ElixIRCd.Services.Chanserv do
  @moduledoc """
  Module for handling incoming ChanServ commands.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Services.Chanserv
  alias ElixIRCd.Tables.User

  @service_commands %{
    "HELP" => Chanserv.Help,
    "REGISTER" => Chanserv.Register,
    "DROP" => Chanserv.Drop,
    "INFO" => Chanserv.Info,
    "SET" => Chanserv.Set,
    "TRANSFER" => Chanserv.Transfer
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
      "ChanServ allows you to register and manage your channels.",
      "For help on using ChanServ, type \x02/msg ChanServ HELP\x02"
    ])
  end

  @spec unknown_command_message(User.t(), String.t()) :: :ok
  defp unknown_command_message(user, service_command) do
    notify(user, [
      "Unknown command: \x02#{service_command}\x02",
      "For help on using ChanServ, type \x02/msg ChanServ HELP\x02"
    ])
  end
end
