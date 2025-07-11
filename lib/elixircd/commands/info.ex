defmodule ElixIRCd.Commands.Info do
  @moduledoc """
  This module defines the INFO command.

  INFO returns information about the server including version, build details, and credits.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @info """
     ____   __   _          ____   ___   _____     __
    / __/  / /  (_) __ __  /  _/  / _ \ / ___/ ___/ /
   / _/   / /  / /  \ \ / _/ /   / , _// /__  / _  /
  /___/  /_/  /_/  /_\_\ /___/  /_/|_| \___/  \_._/

       https://github.com/faelgabriel/elixircd


  This is an ElixIRCd server running version #{Application.spec(:elixircd, :vsn)}.
  It was compiled with Elixir #{System.version()} and Erlang/OTP #{:erlang.system_info(:otp_release)}.

  ElixIRCd is released under the AGPL-3.0 license.

  Developer:
  * Rafael Gabriel (faelgabriel)

  Bugs and feature requests:
  https://github.com/faelgabriel/elixircd/issues

  --------------------------------------------------------
  """

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "INFO"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "INFO"}) do
    @info
    |> String.split("\n")
    |> Enum.map(&Message.build(%{prefix: :server, command: :rpl_info, params: [user.nick], trailing: &1}))
    |> Dispatcher.broadcast(user)

    app_start_time = :persistent_term.get(:app_start_time) |> Calendar.strftime("%a %b %d %Y at %H:%M:%S %Z")
    server_start_time = :persistent_term.get(:server_start_time) |> Calendar.strftime("%a %b %d %H:%M:%S %Y")

    [
      Message.build(%{
        prefix: :server,
        command: :rpl_info,
        params: [user.nick],
        trailing: "Birth Date: #{app_start_time}, compile # 1"
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_info,
        params: [user.nick],
        trailing: "On-line since #{server_start_time}"
      }),
      Message.build(%{prefix: :server, command: :rpl_endofinfo, params: [user.nick], trailing: "End of /INFO list"})
    ]
    |> Dispatcher.broadcast(user)
  end
end
