defmodule ElixIRCd.Factory do
  @moduledoc """
  This module defines the factories for the schemas.
  """

  alias ElixIRCd.Schemas.Channel
  alias ElixIRCd.Schemas.User
  alias ElixIRCd.Schemas.UserChannel

  def build(:channel) do
    %Channel{
      name: "#channel_name"
    }
  end

  def build(:user) do
    %User{
      socket: build(:port),
      transport: :ranch_tcp,
      nick: "Nick",
      hostname: "test",
      username: "test",
      realname: "test",
      identity: "test"
    }
  end

  def build(:user_channel) do
    %UserChannel{
      user: build(:user),
      channel: build(:channel)
    }
  end

  def build(:port) do
    Port.open({:spawn, "cat"}, [:binary])
  end

  def build(factory_name, attributes) do
    factory_name |> build() |> struct!(attributes)
  end
end
