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

  describe "supervision" do
    test "Presence and the app task supervisor run under the application supervisor" do
      children =
        Chatterhead.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(&elem(&1, 0))

      assert is_pid(Process.whereis(Presence))
      assert Presence in children
      assert Chatterhead.TaskSupervisor in children
    end
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

    test "the events topic never carries a raw presence_diff", %{user: user} do
      id = user.id
      tab = start_tracker(user)
      assert_receive {:user_online, %{id: ^id}}, 1000
      Process.exit(tab, :kill)
      assert_receive {:user_offline, %{id: ^id}}, 1000

      # A subscriber to events_topic/0 is tracking on a different topic and must
      # never see Presence's raw diff struct.
      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end
  end

  describe "untrack_page/2" do
    test "drops the named page's presence and publishes :user_offline", %{user: user} do
      id = user.id
      start_tracker(user, "page-a")
      assert_receive {:user_online, %{id: ^id}}, 1000

      assert :ok = Presence.untrack_page(user, "page-a")

      assert_receive {:user_offline, %{id: ^id}}, 1000
      eventually(fn -> refute Map.has_key?(Presence.online_users(), id) end)
    end

    test "another tab of the same user keeps them online", %{user: user} do
      id = user.id
      start_tracker(user, "page-a")
      start_tracker(user, "page-b")
      assert_receive {:user_online, %{id: ^id}}, 1000

      assert :ok = Presence.untrack_page(user, "page-a")

      refute_receive {:user_offline, %{id: ^id}}, 300
      assert Map.has_key?(Presence.online_users(), id)
    end

    # What makes the pagehide beacon safe to fire on every navigation: the beacon
    # for the page being left is already in flight while the page being navigated
    # to connects, and it must not be able to unseat it.
    test "a page id this user does not hold is a no-op", %{user: user} do
      id = user.id
      start_tracker(user, "page-current")
      assert_receive {:user_online, %{id: ^id}}, 1000

      assert :ok = Presence.untrack_page(user, "page-already-closed")

      refute_receive {:user_offline, %{id: ^id}}, 300
      assert Map.has_key?(Presence.online_users(), id)
    end

    test "one user's page id cannot drop another user", %{user: user} do
      id = user.id
      {:ok, other} = Accounts.join("other-#{System.unique_integer([:positive])}")
      start_tracker(user, "shared-page-id")
      assert_receive {:user_online, %{id: ^id}}, 1000

      assert :ok = Presence.untrack_page(other, "shared-page-id")

      refute_receive {:user_offline, %{id: ^id}}, 300
      assert Map.has_key?(Presence.online_users(), id)
    end
  end

  describe "last_seen_at persistence" do
    test "the last tab closing persists last_seen_at, equal to the broadcast at", %{user: user} do
      id = user.id
      assert Accounts.get_user!(id).last_seen_at == nil

      tab = start_tracker(user)
      assert_receive {:user_online, %{id: ^id}}, 1000

      Process.exit(tab, :kill)
      assert_receive {:user_offline, %{id: ^id, at: at}}, 1000

      # The write runs in a supervised task; async: false puts the Repo in
      # shared mode so it finds a connection. eventually/2 waits for it.
      eventually(fn -> assert Accounts.get_user!(id).last_seen_at == at end)
    end
  end

  defp start_tracker(user, page_id \\ nil) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _ref} = Presence.track_user(self(), user, page_id)
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
