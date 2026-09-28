defmodule ElixIRCd.Operators.Sessions do
  @moduledoc "Revokes IRC operator privileges after credential changes."

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @operator_modes [:o, :H, :s]

  @doc "Revokes sessions whose file credential disappeared or changed on reload."
  @spec revoke_changed_config(keyword(), keyword()) :: :ok
  def revoke_changed_config(old, new) do
    new_hashes = Map.new(new)

    Enum.each(old, fn {name, old_hash} ->
      if Map.get(new_hashes, name) != old_hash, do: revoke(:config, name)
    end)

    :ok
  end

  @doc "Clears matching sessions inside an existing Mnesia transaction."
  @spec clear(:config | :database, String.t()) :: [{User.t(), [atom()]}]
  def clear(source, name) do
    Users.get_all()
    |> Enum.filter(&(&1.oper_source == source and &1.oper_name == name))
    |> Enum.map(fn user ->
      modes = Enum.reject(user.modes, &(&1 in @operator_modes))
      updated = Users.update(user, %{modes: modes, oper_source: nil, oper_name: nil})
      removed = Enum.filter(@operator_modes, &(&1 in user.modes))
      {updated, removed}
    end)
  end

  @doc "Sends mode changes for revoked operator sessions."
  @spec notify_revoked([{User.t(), [atom()]}]) :: :ok
  def notify_revoked(revoked) do
    Enum.each(revoked, fn
      {%User{nick: nick} = user, [_ | _] = removed} when is_binary(nick) ->
        modes = Enum.map_join(removed, &Atom.to_string/1)
        Dispatcher.broadcast(%Message{command: "MODE", params: [nick, "-" <> modes]}, :server, user)

      _ ->
        :ok
    end)

    :ok
  end

  @spec revoke(:config | :database, String.t()) :: :ok
  defp revoke(source, name) do
    Memento.transaction!(fn -> clear(source, name) end)
    |> notify_revoked()
  end
end
