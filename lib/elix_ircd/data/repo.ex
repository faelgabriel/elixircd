defmodule ElixIRCd.Data.Repo do
  @moduledoc """
  ETS Repo
  """

  use Ecto.Repo, otp_app: :elixircd, adapter: Etso.Adapter
end
