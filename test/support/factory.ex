defmodule ElixIRCd.Factory do
  @moduledoc """
  This module defines the factories for the schemas.
  """

  use ExMachina.Ecto, repo: ElixIRCd.Data.Repo

  alias ElixIRCd.Data.Schemas.Channel
  alias ElixIRCd.Data.Schemas.User
  alias ElixIRCd.Data.Schemas.UserChannel

  @doc false
  @spec create_socket(:tcp | :ssl) :: :inet.socket()
  def create_socket(:tcp), do: Port.open({:spawn, "cat /dev/null"}, [:binary])

  def create_socket(:ssl) do
    port = Port.open({:spawn, "cat /dev/null"}, [:binary])
    pid = self()

    {:sslsocket,
     {:gen_tcp, port, :tls_connection,
      [option_tracker: pid, session_tickets_tracker: :disabled, session_id_tracker: pid]}, [pid, pid]}
  end

  @doc false
  @spec channel_factory() :: Channel.t()
  def channel_factory do
    %Channel{
      name: "##{sequence("channel_name")}",
      topic: "Channel topic"
    }
  end

  @doc false
  @spec user_factory() :: User.t()
  def user_factory do
    %User{
      socket: create_socket(:tcp),
      transport: :ranch_tcp,
      pid: self(),
      nick: "#{sequence("Nick")}",
      hostname: "test",
      username: "test",
      realname: "test",
      identity: "test"
    }
  end

  @doc false
  @spec user_channel_factory() :: UserChannel.t()
  def user_channel_factory do
    %UserChannel{
      user: build(:user),
      channel: build(:channel)
    }
  end
end
