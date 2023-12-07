defmodule ElixIRCd.Factory do
  @moduledoc """
  This module defines the factories for the schemas.
  """

  use ExMachina.Ecto, repo: ElixIRCd.Data.Repo

  alias ElixIRCd.Data.Schemas.Channel
  alias ElixIRCd.Data.Schemas.User
  alias ElixIRCd.Data.Schemas.UserChannel

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
      socket: Port.open({:spawn, "cat /dev/null"}, [:binary]),
      transport: :ranch_tcp,
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
