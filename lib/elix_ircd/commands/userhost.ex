# defmodule ElixIRCd.Commands.Userhost do
#   @moduledoc """
#   This module defines the USERHOST command.
#   """
#   alias ElixIRCd.Handlers.MessageHandler
#   alias ElixIRCd.Schemas.User, as: UserSchema
#   alias ElixIRCd.Handlers.StorageHandler

#   @behaviour ElixIRCd.Behaviors.Command

#   @impl true
#   def handle(user, [nicks]) when user.identity != nil do
#     MessageHandler.userhost(socket, user_data, nicks)
#   end

#   def handle({socket, %{identity: _} = user_data}, [[nicknames]]) do
#     nicknames = String.split(nicknames, " ")
#     userhost = Enum.map(nicknames, fn nickname ->
#       case storage().lookup_user_by_nick(nickname) do
#         {nil, nil} -> nil
#         {_, %{identity: identity}} -> "#{nickname}=+#{identity.username}@#{identity.hostname}"
#       end
#     end) |> Enum.reject(&is_nil/1) |> Enum.join(" ")

#     userhost_message(socket, user_data, userhost)
#   end

#   Not really working yet
#   def userhost_message(user, nicks) do
#     userhost_list =
#       nicks
#       |> Enum.map(&storage().lookup_user_by_nick(&1))
#       |> Enum.map(fn
#         {:error, _} ->
#           "-"

#         {:ok, user} ->
#           "#{user.identity}"
#       end)
#       |> Enum.join(" ")

#     MessageHandler.send_message(user, :server, "302 #{user.nick} #{userhost_list}")
#   end
# end
