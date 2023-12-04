defmodule ElixIRCd.Factory do
  @moduledoc """
  This module defines the factories for the schemas.
  """

  alias ElixIRCd.Data.Schemas.Channel
  alias ElixIRCd.Data.Schemas.User
  alias ElixIRCd.Data.Schemas.UserChannel

  use ExMachina.Ecto, repo: ElixIRCd.Data.Repo

  def channel_factory do
    %Channel{
      name: "#channel_name",
      topic: "Channel topic"
    }
  end

  def user_factory do
    %User{
      socket: Port.open({:spawn, "cat"}, [:binary]),
      transport: :ranch_tcp,
      nick: "Nick",
      hostname: "test",
      username: "test",
      realname: "test",
      identity: "test"
    }
  end

  def user_channel_factory do
    %UserChannel{
      user: build(:user),
      channel: build(:channel)
    }
  end
end
