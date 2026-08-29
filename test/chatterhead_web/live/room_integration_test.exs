defmodule ChatterheadWeb.RoomIntegrationTest do
  # The tests that prove the feature rather than the units: two simultaneous
  # LiveView connections exchanging messages and observing each other's presence.
  use ChatterheadWeb.ConnCase, async: false

  import Chatterhead.PresenceCase

  alias Chatterhead.Accounts

  setup do
    on_exit(&drain_presence_fetchers/0)
    :ok
  end

  describe "message fan-out" do
    test "a message sent from one connection renders in both, with no local echo" do
      {_alice, alice_view} = join_room("alice-fanout")
      {_bob, bob_view} = join_room("bob-fanout")

      alice_view
      |> form("#message-form", message: %{body: "hello from alice"})
      |> render_submit()

      # bob sees it
      assert render(bob_view) =~ "hello from alice"
      # so does alice -- via the same PubSub broadcast, not a client-side insert
      assert render(alice_view) =~ "hello from alice"
    end

    test "interleaved messages render in identical order in both connections" do
      {_alice, alice_view} = join_room("alice-order")
      {_bob, bob_view} = join_room("bob-order")

      alice_view |> form("#message-form", message: %{body: "line-1-alice"}) |> render_submit()
      bob_view |> form("#message-form", message: %{body: "line-2-bob"}) |> render_submit()
      alice_view |> form("#message-form", message: %{body: "line-3-alice"}) |> render_submit()

      for view <- [alice_view, bob_view] do
        assert in_order(render(view), ~w(line-1-alice line-2-bob line-3-alice))
      end
    end
  end

  describe "presence" do
    test "a joining connection appears in an open client's roster, and leaves it on disconnect" do
      {_alice, alice_view} = join_room("alice-pres-int")
      {bob, bob_view} = join_room("bob-pres-int")

      eventually(fn ->
        assert has_element?(alice_view, "#roster-user-#{bob.id}[data-online='true']")
      end)

      disconnect(bob_view)

      eventually(fn ->
        assert has_element?(alice_view, "#roster-user-#{bob.id}[data-online='false']")
      end)

      # bob was here -- his entry carries a real last-seen label
      entry = alice_view |> element("#roster-user-#{bob.id}") |> render()
      assert entry =~ "just now"
    end

    test "multi-tab across two real connections: one tab closing keeps the user online" do
      {_alice, alice_view} = join_room("alice-tab-int")
      {bob, bob_tab1} = join_room("bob-tab-int")
      {^bob, bob_tab2} = join_room("bob-tab-int")

      eventually(fn ->
        assert has_element?(alice_view, "#roster-user-#{bob.id}[data-online='true']")
      end)

      disconnect(bob_tab1)

      Process.sleep(200)
      assert has_element?(alice_view, "#roster-user-#{bob.id}[data-online='true']")

      disconnect(bob_tab2)

      eventually(fn ->
        assert has_element?(alice_view, "#roster-user-#{bob.id}[data-online='false']")
      end)
    end

    test "a user created after an open client mounted still appears in its roster" do
      {_alice, alice_view} = join_room("alice-newcomer-int")

      # carl does not exist when alice mounts
      {carl, _carl_view} = join_room("carl-newcomer-int")

      eventually(fn ->
        assert has_element?(alice_view, "#roster-user-#{carl.id}[data-online='true']")
      end)
    end
  end

  defp join_room(name) do
    {:ok, user} = Accounts.join(name)
    {:ok, view, _html} = build_conn() |> log_in(user) |> live(~p"/room")
    {user, view}
  end

  defp in_order(html, needles) do
    positions = Enum.map(needles, &(:binary.match(html, &1) |> elem(0)))
    positions == Enum.sort(positions)
  end
end
