defmodule ChatterheadWeb.PresenceTest do
  # async: false: Presence is a global, unsandboxed process.
  use Chatterhead.DataCase, async: false

  import Chatterhead.PresenceCase

  alias Chatterhead.Accounts
  alias ChatterheadWeb.Presence

  setup do
    on_exit(&drain_presence_fetchers/0)
    # A prior serial test's leave may still be converging; start from a clean slate.
    eventually(fn -> assert Presence.online_users() == %{} end)
    # A per-test user, so its id scopes every assertion and no event from a
    # previous test can be mistaken for this one's.
    {:ok, user} = Accounts.join("presence-user-#{System.unique_integer([:positive])}")
    %{user: user}
  end

  describe "track_user/2 and online_users/0" do
    test "a tracked process appears keyed by integer id", %{user: user} do
      start_tracker(user)
      %{id: id, name: name} = user

      eventually(fn ->
        assert %{^id => %{id: ^id, name: ^name}} = Presence.online_users()
      end)
    end

    test "killing the tracked process removes the entry", %{user: user} do
      pid = start_tracker(user)
      id = user.id

      eventually(fn -> assert Map.has_key?(Presence.online_users(), id) end)

      Process.exit(pid, :kill)

      eventually(fn -> refute Map.has_key?(Presence.online_users(), id) end)
    end

    test "two processes for the same user yield exactly one entry", %{user: user} do
      start_tracker(user)
      start_tracker(user)
      id = user.id

      eventually(fn -> assert Map.keys(Presence.online_users()) == [id] end)
    end
  end

  defp start_tracker(user) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _ref} = Presence.track_user(self(), user)
        send(test, {:tracked, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:tracked, ^pid}
    on_exit(fn -> stop_tracker(pid) end)
    pid
  end

  defp stop_tracker(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, :stop)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> Process.demonitor(ref, [:flush])
      end
    end
  end
end
