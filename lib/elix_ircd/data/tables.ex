defmodule ElixIRCd.Data.Tables do
  def setup() do
    Memento.Table.create(ElixIRCd.Data.Tables.User)
    Memento.Table.create(ElixIRCd.Data.Tables.Channel)
    Memento.Table.create(ElixIRCd.Data.Tables.UserChannel)
  end
end
