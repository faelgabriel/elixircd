defmodule ElixIRCd.Repositories.RegisteredNicksTest do
  @moduledoc false

	use ElixIRCd.DataCase, async: false

	import ElixIRCd.Factory

	alias ElixIRCd.Repositories.RegisteredNicks
	alias ElixIRCd.Tables.RegisteredNick

	describe "create/1" do
		test "creates a new registered nickname" do
			attrs = %{
				nickname: "testnick",
				password_hash: "hash123",
				registered_by: "user@host"
			}

			registered_nick = Memento.transaction!(fn -> RegisteredNicks.create(attrs) end)

			assert registered_nick.nickname == "testnick"
			assert registered_nick.password_hash == "hash123"
			assert registered_nick.registered_by == "user@host"
		end
	end

	describe "get_by_nickname/1" do
		test "returns a registered nickname by its nickname" do
			registered_nick = insert(:registered_nick)

			assert {:ok, registered_nick} == Memento.transaction!(fn -> RegisteredNicks.get_by_nickname(registered_nick.nickname) end)
		end

		test "returns an error when the registered nickname is not found" do
			assert {:error, :registered_nick_not_found} == Memento.transaction!(fn -> RegisteredNicks.get_by_nickname("nonexistent") end)
		end
	end

	describe "get_all/0" do
		test "returns all registered nicknames" do
			registered_nick1 = insert(:registered_nick)
			registered_nick2 = insert(:registered_nick)

			registered_nicks = Memento.transaction!(fn -> RegisteredNicks.get_all() end)

			assert length(registered_nicks) == 2
			assert Enum.any?(registered_nicks, fn nick -> nick.nickname == registered_nick1.nickname end)
			assert Enum.any?(registered_nicks, fn nick -> nick.nickname == registered_nick2.nickname end)
		end

		test "returns an empty list when no registered nicknames exist" do
			assert [] == Memento.transaction!(fn -> RegisteredNicks.get_all() end)
		end
	end

	describe "update/2" do
		test "updates a registered nickname with new values" do
			registered_nick = insert(:registered_nick)

			attrs = %{
				email: "updated@example.com",
				verified_at: DateTime.utc_now()
			}

			updated_nick = Memento.transaction!(fn -> RegisteredNicks.update(registered_nick, attrs) end)

			assert updated_nick.email == "updated@example.com"
			assert updated_nick.verified_at != nil
		end
	end

	describe "delete/1" do
		test "deletes a registered nickname" do
			registered_nick = insert(:registered_nick)

			Memento.transaction!(fn -> RegisteredNicks.delete(registered_nick) end)

			assert nil == Memento.transaction!(fn -> Memento.Query.read(RegisteredNick, registered_nick.nickname) end)
		end
	end
end
