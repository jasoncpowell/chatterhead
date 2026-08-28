defmodule Chatterhead.AccountsJoinRaceTest do
  # async: false on purpose. The spawned tasks below do not own a sandbox
  # connection, so the Repo has to be in shared mode -- which this scaffold's
  # DataCase gives any `async: false` module. `async` is module-level in ExUnit,
  # so this one concurrency test lives in its own file rather than forcing shared
  # mode on the rest of the Accounts suite. See docs/02-implementation-plan.md 6.2.
  use Chatterhead.DataCase, async: false

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.User

  test "two concurrent joins for the same new name converge on one row" do
    name = "racer-#{System.unique_integer([:positive])}"

    task1 = Task.async(fn -> Accounts.join(name) end)
    task2 = Task.async(fn -> Accounts.join(name) end)

    assert [{:ok, %User{id: id1}}, {:ok, %User{id: id2}}] = Task.await_many([task1, task2])
    assert id1 == id2
    assert Repo.aggregate(User, :count) == 1
  end
end
