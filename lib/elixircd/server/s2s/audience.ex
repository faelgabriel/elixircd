defmodule ElixIRCd.Server.S2S.Audience do
  @moduledoc """
  Publishes operator/server notifications through the native S2S message path.

  C2S command handlers keep their existing local formatting and recipient
  selection. The network representation uses the closed ENP message contract
  with a NOTICE command and an audience target, so recipient homes apply their
  own local mode and snomask policy.
  """

  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Tables.User

  @audiences ~w(wallops operators snomask)

  @doc "Publishes one authorized operator or server audience notification."
  @spec publish(User.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def publish(user, audience, message, mask \\ nil)

  def publish(%User{uid: uid}, audience, message, mask)
      when is_binary(uid) and audience in @audiences and is_binary(message) and
             (is_nil(mask) or is_binary(mask)) do
    case Process.whereis(Manager) do
      manager when is_pid(manager) ->
        _ =
          Manager.publish_message(
            manager,
            uid,
            %{"audience" => audience, "mask" => mask},
            "NOTICE",
            message,
            %{},
            nil,
            deliver_local: false
          )

        :ok

      _ ->
        :ok
    end
  end

  def publish(_user, _audience, _message, _mask), do: :ok
end
