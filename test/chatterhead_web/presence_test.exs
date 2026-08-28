defmodule ChatterheadWeb.PresenceTest do
  # async: false: Presence is a global, unsandboxed process.
  use Chatterhead.DataCase, async: false

  import Chatterhead.PresenceCase

  alias Chatterhead.Accounts
  alias ChatterheadWeb.Presence

  setup do
    on_exit(&drain_presence_fetchers/0)
    # A prior serial test's leave may still be converging; wait for a clean slate
    # *before* subscribing, so no earlier test's :user_offline lands here.
    eventually(fn -> assert Presence.online_users() == %{} end)
    :ok = Phoenix.PubSub.subscribe(Chatterhead.PubSub, Presence.events_topic())

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

  describe "presence client events" do
    test "tracking a user publishes exactly one :user_online", %{user: user} do
      %{id: id, name: name} = user
      start_tracker(user)

      assert_receive {:user_online, %{id: ^id, name: ^name}}, 1000
      refute_receive {:user_online, %{id: ^id}}, 100
    end

    test "a second tab for the same user publishes no further :user_online", %{user: user} do
      id = user.id
      start_tracker(user)
      assert_receive {:user_online, %{id: ^id}}, 1000

      start_tracker(user)
      refute_receive {:user_online, %{id: ^id}}, 200
    end

    test "closing one of two tabs publishes no :user_offline", %{user: user} do
      id = user.id
      tab1 = start_tracker(user)
      _tab2 = start_tracker(user)
      assert_receive {:user_online, %{id: ^id}}, 1000

      Process.exit(tab1, :kill)
      refute_receive {:user_offline, %{id: ^id}}, 300
    end

    test "closing the last tab publishes one :user_offline with a second-precision at", %{
      user: user
    } do
      id = user.id
      tab1 = start_tracker(user)
      tab2 = start_tracker(user)
      assert_receive {:user_online, %{id: ^id}}, 1000

      Process.exit(tab1, :kill)
      Process.exit(tab2, :kill)

      assert_receive {:user_offline, %{id: ^id, name: _name, at: %DateTime{} = at}}, 1000
      assert at == DateTime.truncate(at, :second)
      refute_receive {:user_offline, %{id: ^id}}, 100
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
