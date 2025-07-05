defmodule ElixIRCd.Commands.Oper do
  @moduledoc """
  This module defines the OPER command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  import ElixIRCd.Utils.Operators, only: [operator_vhost: 1]

  alias ElixIRCd.Commands.Mode.UserModes
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "OPER"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "OPER", params: params}) when length(params) <= 1 do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "OPER"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "OPER", params: [username, password | _rest]}) do
    user_hostmask = user_mask(user)

    case validate_operator_credential(username, password, user_hostmask) do
      {:ok, operator_config} ->
        authenticate_operator(user, operator_config)

      :error ->
        Message.build(%{
          prefix: :server,
          command: :err_passwdmismatch,
          params: [user.nick],
          trailing: "Password incorrect"
        })
        |> Dispatcher.broadcast(user)
    end
  end

  @spec validate_operator_credential(String.t(), String.t(), String.t()) ::
          {:ok, map()} | :error
  defp validate_operator_credential(nick, password, hostmask) do
    Application.get_env(:elixircd, :operators, [])
    |> Enum.find(fn operator ->
      operator.nick == nick and
        Argon2.verify_pass(password, operator.password) and
        hostmask_matches?(hostmask, operator.hostmasks)
    end)
    |> case do
      nil -> :error
      operator -> {:ok, operator}
    end
  end

  @spec hostmask_matches?(String.t(), [String.t()]) :: boolean()
  defp hostmask_matches?(user_hostmask, allowed_hostmasks) do
    Enum.any?(allowed_hostmasks, fn pattern ->
      match_hostmask_pattern?(user_hostmask, pattern)
    end)
  end

  @spec match_hostmask_pattern?(String.t(), String.t()) :: boolean()
  defp match_hostmask_pattern?(user_hostmask, pattern) do
    regex_pattern =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("@", "\\@")
      |> String.replace("!", "\\!")
      |> String.replace("*", ".*")

    case Regex.compile(regex_pattern) do
      {:ok, regex} -> Regex.match?(regex, user_hostmask)
      {:error, _} -> false
    end
  end

  @spec authenticate_operator(User.t(), map()) :: :ok
  defp authenticate_operator(user, operator_config) do
    # Set internal operator state
    new_operator = User.Operator.new(%{
      nick: operator_config.nick,
      type: operator_config.type
    })

    updated_user = Users.update(user, %{operator: new_operator})

    # Apply hardcoded +O operator mode
    final_user = apply_operator_mode(updated_user)

    # Optionally set vhost
    final_user = maybe_set_operator_vhost(final_user, operator_config)

    # Send success message
    Message.build(%{
      prefix: :server,
      command: :rpl_youreoper,
      params: [final_user.nick],
      trailing: "You are now an IRC operator"
    })
    |> Dispatcher.broadcast(final_user)

    # Log operator authentication
    require Logger

    Logger.info("User #{final_user.nick} authenticated as IRC operator (#{operator_config.type})")
  end

  @spec apply_operator_mode(User.t()) :: User.t()
  defp apply_operator_mode(user) do
    # Apply hardcoded +O operator mode
    {mode_changes, _invalid} = UserModes.parse_mode_changes("+O")
    {updated_user, _applied, _unauthorized} = UserModes.apply_mode_changes(user, mode_changes)
    updated_user
  end

  @spec maybe_set_operator_vhost(User.t(), map()) :: User.t()
  defp maybe_set_operator_vhost(user, operator_config) do
    case operator_vhost(operator_config) do
      nil -> user
      vhost -> Users.update(user, %{hostname: vhost})
    end
  end
end
