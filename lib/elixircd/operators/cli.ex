defmodule ElixIRCd.Operators.CLI do
  @moduledoc "Operator commands for the administrative release CLI."

  alias ElixIRCd.CLI.Remote
  alias ElixIRCd.Operators

  @commands [
    {"list", "list", "List operators and their source and status"},
    {"add", "add NAME", "Add a database operator; prompts for a password"},
    {"passwd", "passwd NAME", "Change a database operator password"},
    {"disable", "disable NAME", "Disable a database operator"},
    {"enable", "enable NAME", "Enable a database operator"},
    {"remove", "remove NAME", "Remove a database operator"},
    {"hash", "hash", "Generate an Argon2id hash without a running server"}
  ]

  @usage "Usage: elixircd oper COMMAND [ARGS]"

  @doc "Runs an operator command and returns printable output or a sanitized error."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run([]), do: {:ok, help()}
  def run([option]) when option in ["help", "--help", "-h"], do: {:ok, help()}
  def run(["help", action]), do: command_help(action)
  def run([action, option]) when option in ["--help", "-h"], do: command_help(action)

  def run(["hash"]) do
    with {:ok, password} <- password_with_confirmation() do
      {:ok, Argon2.hash_pwd_salt(password)}
    end
  end

  def run(["list"]) do
    with {:ok, server_node} <- Remote.connect("oper") do
      format_list(Operators.Remote.call(server_node, :list, []))
    end
  end

  def run([action, name]) when action in ["add", "passwd"] do
    with {:ok, server_node} <- Remote.connect("oper"),
         {:ok, password} <- password_with_confirmation() do
      hash = Argon2.hash_pwd_salt(password)
      operation = if action == "add", do: :add, else: :rotate
      result_message(Operators.Remote.call(server_node, operation, [name, hash]), action, name)
    end
  end

  def run([action, name]) when action in ["disable", "enable", "remove"] do
    with {:ok, server_node} <- Remote.connect("oper") do
      operation =
        case action do
          "disable" -> :disable
          "enable" -> :enable
          "remove" -> :remove
        end

      result_message(Operators.Remote.call(server_node, operation, [name]), action, name)
    end
  end

  def run(_args), do: {:error, "Invalid operator command or arguments\n\n#{help()}"}

  defp command_help(action) do
    case Enum.find(@commands, fn {name, _usage, _description} -> name == action end) do
      {_name, usage, description} ->
        details =
          if action in ["add", "passwd", "hash"] do
            "Passwords are entered twice in a terminal and are never accepted as arguments."
          else
            "Database operators can be managed here; config file operators are read-only."
          end

        {:ok, "Usage: elixircd oper #{usage}\n\n#{description}.\n\n#{details}"}

      nil ->
        {:error, "Unknown operator command: #{action}\n\n#{help()}"}
    end
  end

  defp help do
    commands =
      Enum.map_join(@commands, "\n", fn {_name, usage, description} ->
        "  #{String.pad_trailing(usage, 15)} #{description}"
      end)

    """
    #{@usage}

    Commands:
    #{commands}

    Run 'elixircd oper help COMMAND' for details.
    """
    |> String.trim_trailing()
  end

  @spec format_list(term()) :: {:ok, String.t()} | {:error, String.t()}
  defp format_list(entries) when is_list(entries) do
    output = Enum.map_join(entries, "\n", &format_entry/1)
    {:ok, if(output == "", do: "No operators configured", else: output)}
  end

  defp format_list(error), do: remote_error(error)

  @spec format_entry({String.t(), :config | :database, boolean()}) :: String.t()
  defp format_entry({name, :config, true}), do: "#{name} (config file; read-only)"
  defp format_entry({name, :database, true}), do: "#{name} (database; enabled)"
  defp format_entry({name, :database, false}), do: "#{name} (database; disabled)"

  @spec password_with_confirmation() :: {:ok, String.t()} | {:error, String.t()}
  defp password_with_confirmation do
    with {:ok, password} <- hidden_password("Password: "),
         true <- byte_size(password) >= 12,
         {:ok, confirmation} <- hidden_password("Confirm password: "),
         true <- password == confirmation do
      {:ok, password}
    else
      false -> {:error, "Password must contain at least 12 bytes and match confirmation"}
      error -> error
    end
  end

  @spec hidden_password(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp hidden_password(prompt) do
    IO.write(:stderr, prompt)

    case IO.gets("") do
      line when is_binary(line) ->
        IO.write(:stderr, "\n")
        {:ok, line |> String.trim_trailing("\n") |> String.trim_trailing("\r")}

      _ ->
        {:error, "Could not read a password from the terminal"}
    end
  end

  @spec result_message(term(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp result_message(:ok, action, name), do: {:ok, "Operator #{name}: #{action} completed"}
  defp result_message({:error, reason}, _action, _name), do: {:error, explain(reason)}
  defp result_message(other, _action, _name), do: remote_error(other)

  @spec explain(atom()) :: String.t()
  defp explain(:configured), do: "Cannot change this operator: managed in config/elixircd.exs (read-only)"
  defp explain(:exists), do: "Operator already exists"
  defp explain(:not_found), do: "Operator not found"
  defp explain(:invalid_name), do: "Invalid operator name"
  defp explain(:invalid_hash), do: "Invalid Argon2 password hash"
  defp explain(_reason), do: "Operator operation failed"

  @spec remote_error(term()) :: {:error, String.t()}
  defp remote_error(_reason), do: {:error, "Operator operation failed; check server availability and logs"}
end
