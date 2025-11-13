defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.

  CAP handles IRCv3 capability negotiation between client and server.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @supported_capabilities %{
    "UHNAMES" => %{
      name: "UHNAMES",
      description: "Extended NAMES reply with full user@host format"
    },
    "EXTENDED-UHLIST" => %{
      name: "EXTENDED-UHLIST",
      description: "Extended user modes in WHO replies"
    },
    "MESSAGE-TAGS" => %{
      name: "MESSAGE-TAGS",
      description: "Support for IRCv3 message tags including bot tag"
    }
  }

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "CAP", params: params, trailing: trailing}) do
    handle_cap_command(user, params, trailing)
  end

  @spec handle_cap_command(User.t(), [String.t()], String.t() | nil) :: :ok
  defp handle_cap_command(user, ["LS"], _trailing), do: handle_cap_ls(user)
  defp handle_cap_command(user, ["LS", _version], _trailing), do: handle_cap_ls(user)
  defp handle_cap_command(user, ["LIST"], _trailing), do: handle_cap_list(user)
  defp handle_cap_command(user, ["REQ", capabilities_string], _trailing), do: handle_cap_req(user, capabilities_string)
  defp handle_cap_command(user, ["REQ"], capabilities_string), do: handle_cap_req(user, capabilities_string)
  defp handle_cap_command(user, ["END"], _trailing), do: handle_cap_end(user)

  defp handle_cap_command(user, params, _trailing) do
    %Message{
      command: "CAP",
      params: [user_reply(user), "NAK"],
      trailing: "Unsupported CAP command: #{Enum.join(params, " ")}"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_cap_ls(User.t()) :: :ok
  defp handle_cap_ls(user) do
    capabilities_list = get_capabilities_list()

    %Message{
      command: "CAP",
      params: [user_reply(user), "LS"],
      trailing: capabilities_list
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_cap_list(User.t()) :: :ok
  defp handle_cap_list(user) do
    enabled_caps = Enum.join(user.capabilities, " ")

    %Message{
      command: "CAP",
      params: [user_reply(user), "LIST"],
      trailing: enabled_caps
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_cap_req(User.t(), String.t()) :: :ok
  defp handle_cap_req(user, capabilities_string) do
    capabilities = parse_capabilities_request(capabilities_string)
    {acked, nacked} = validate_capabilities(capabilities)

    if length(nacked) > 0 do
      %Message{
        command: "CAP",
        params: [user_reply(user), "NAK"],
        trailing: capabilities_string
      }
      |> Dispatcher.broadcast(:server, user)
    else
      updated_user = apply_capability_changes(user, acked)

      %Message{
        command: "CAP",
        params: [user_reply(user), "ACK"],
        trailing: capabilities_string
      }
      |> Dispatcher.broadcast(:server, updated_user)
    end
  end

  @spec handle_cap_end(User.t()) :: :ok
  defp handle_cap_end(_user) do
    :ok
  end

  @spec get_capabilities_list() :: String.t()
  defp get_capabilities_list do
    extended_names_supported = Application.get_env(:elixircd, :capabilities)[:extended_names] || false
    extended_uhlist_supported = Application.get_env(:elixircd, :capabilities)[:extended_uhlist] || false
    message_tags_supported = Application.get_env(:elixircd, :capabilities)[:message_tags] || false
    base_caps = []

    caps =
      if extended_names_supported do
        ["UHNAMES" | base_caps]
      else
        base_caps
      end

    caps =
      if extended_uhlist_supported do
        ["EXTENDED-UHLIST" | caps]
      else
        caps
      end

    caps =
      if message_tags_supported do
        ["MESSAGE-TAGS" | caps]
      else
        caps
      end

    Enum.join(caps, " ")
  end

  @spec parse_capabilities_request(String.t()) :: [%{action: :enable | :disable, name: String.t()}]
  defp parse_capabilities_request(capabilities_string) do
    capabilities_string
    |> String.split()
    |> Enum.map(&parse_single_capability/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec parse_single_capability(String.t()) :: %{action: :enable | :disable, name: String.t()} | nil
  defp parse_single_capability("-" <> capability) do
    %{action: :disable, name: String.upcase(capability)}
  end

  defp parse_single_capability(capability) do
    %{action: :enable, name: String.upcase(capability)}
  end

  @spec validate_capabilities([%{action: :enable | :disable, name: String.t()}]) ::
          {[%{action: :enable | :disable, name: String.t()}], [String.t()]}
  defp validate_capabilities(capabilities) do
    Enum.split_with(capabilities, fn cap ->
      Map.has_key?(@supported_capabilities, cap.name)
    end)
  end

  @spec apply_capability_changes(User.t(), [%{action: :enable | :disable, name: String.t()}]) :: User.t()
  defp apply_capability_changes(user, capabilities) do
    new_capabilities =
      Enum.reduce(capabilities, user.capabilities, fn cap, acc ->
        apply_capability_change(cap, acc)
      end)

    Users.update(user, %{capabilities: new_capabilities})
  end

  @spec apply_capability_change(%{action: :enable | :disable, name: String.t()}, [String.t()]) :: [String.t()]
  defp apply_capability_change(%{action: :enable, name: name}, acc) do
    if name in acc, do: acc, else: [name | acc]
  end

  defp apply_capability_change(%{action: :disable, name: name}, acc) do
    List.delete(acc, name)
  end
end
