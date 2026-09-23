defmodule ElixIRCd.Server.S2S.PolicyStoreTest do
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.PolicyStore

  test "allocates revisions under the durable epoch write lock" do
    epoch = Identity.nonce()

    assert {:ok, 3} = PolicyStore.next_revision(epoch, 2)
    assert {:ok, 4} = PolicyStore.next_revision(epoch, 0)
    assert %{epoch: ^epoch, revision: 4} = PolicyStore.read()
  end

  test "does not allocate a revision from another policy epoch" do
    first = Identity.nonce()
    second = Identity.nonce()

    assert {:ok, _revision} = PolicyStore.next_revision(first, 0)
    assert {:error, :policy_epoch_mismatch} = PolicyStore.next_revision(second, 0)
    assert %{epoch: ^first} = PolicyStore.read()
  end
end
