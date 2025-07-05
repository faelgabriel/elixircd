defmodule ElixIRCd.Utils.Operators do
  @moduledoc """
  Utility functions for IRC operator management.
  """

  alias ElixIRCd.Tables.User



  @doc """
  Checks if a user has a specific operator privilege.
  """
  @spec has_operator_privilege?(User.t(), atom()) :: boolean()
  def has_operator_privilege?(%User{operator: nil}, _priv), do: false

  def has_operator_privilege?(%User{operator: %{type: nil}}, _priv), do: false

  def has_operator_privilege?(%User{operator: %{type: type}}, priv) do
    operator_types = Application.get_env(:elixircd, :operator_types, %{})

    case Map.get(operator_types, type) do
      nil -> false
      %{privs: privs} -> priv in privs
      _ -> false
    end
  end

  @doc """
  Returns the list of privileges for an operator type.
  """
  @spec operator_privileges(String.t()) :: [atom()]
  def operator_privileges(type) do
    operator_types = Application.get_env(:elixircd, :operator_types, %{})

    case Map.get(operator_types, type) do
      nil -> []
      %{privs: privs} -> privs
      _ -> []
    end
  end



  @doc """
  Returns the vhost for an operator, if defined.
  """
  @spec operator_vhost(map()) :: String.t() | nil
  def operator_vhost(%{vhost: vhost}), do: vhost
  def operator_vhost(_), do: nil
end
