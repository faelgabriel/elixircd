defmodule ElixIRCd.Service do
  @moduledoc """
  Module for handling incoming service commands.
  """

  alias ElixIRCd.Observability
  alias ElixIRCd.Services
  alias ElixIRCd.Tables.User

  @services %{
    "CHANSERV" => Services.Chanserv,
    "NICKSERV" => Services.Nickserv
  }

  @service_identities %{
    chanserv: {"ChanServ", "service"},
    nickserv: {"NickServ", "service"}
  }

  @type service :: :chanserv | :nickserv

  @doc """
  Defines the behaviour for handling incoming service commands.
  """
  @callback handle(user :: User.t(), command_list :: [String.t()]) :: :ok

  @doc """
  Checks if a service is implemented.
  """
  @spec service_implemented?(String.t()) :: boolean()
  def service_implemented?(target_service) do
    normalized_target_service = String.upcase(target_service)
    Map.has_key?(@services, normalized_target_service)
  end

  @doc """
  Dispatches a service command to the appropriate module that implements the `ElixIRCd.Service` behaviour.
  The target service is required to be a valid service name.
  """
  @spec dispatch(User.t(), String.t(), [String.t()]) :: :ok
  def dispatch(user, target_service, command_list) do
    normalized_target_service = String.upcase(target_service)
    service_module = Map.fetch!(@services, normalized_target_service)
    command = command_list |> List.first() |> to_string() |> String.upcase()
    bounded_command = if command in service_module.names(), do: command, else: "OTHER"
    result = service_module.handle(user, command_list)

    Observability.defer([:service], %{count: 1}, %{
      service: normalized_target_service,
      command: bounded_command,
      result: :handled
    })

    result
  end

  @doc "Returns the canonical IRC mask for a network service."
  @spec mask(service()) :: String.t()
  def mask(service) do
    {nick, ident} = Map.fetch!(@service_identities, service)
    hostname = Application.fetch_env!(:elixircd, :server)[:hostname]
    "#{nick}!#{ident}@#{hostname}"
  end
end
