defmodule ChatterheadWeb.RoomIntegrationTest do
  # The tests that prove the feature rather than the units: two simultaneous
  # LiveView connections exchanging messages and observing each other's presence.
  use ChatterheadWeb.ConnCase, async: false

  # `mix test --exclude integration` skips these for a faster local loop.
  @moduletag :integration

  import Chatterhead.PresenceCase

  alias Chatterhead.Accounts
  alias Chatterhead.Chat
  alias Chatterhead.Chat.Message
  alias Chatterhead.Repo

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

  describe "history under a live conversation" do
    test "paging back while another client sends skips and duplicates nothing" do
      size = Chat.page_size()
      total = size + 10

      {:ok, alice} = Accounts.join("alice-hist")
      seed(alice, total)

      {_alice, alice_view} = join_room("alice-hist")
      {_bob, bob_view} = join_room("bob-hist")

      assert has_element?(alice_view, "#load-older")

      for n <- 1..3 do
        bob_view |> form("#message-form", message: %{body: "live-#{n}"}) |> render_submit()
      end

      assert render(alice_view) =~ "live-3"

      alice_view |> element("#load-older") |> render_click()

      html = render(alice_view)

      for i <- 1..total do
        assert html =~ "seed-#{pad(i)}", "missing seed-#{pad(i)} after paging back"
        assert count(html, "seed-#{pad(i)}") == 1, "seed-#{pad(i)} rendered more than once"
      end

      for n <- 1..3 do
        assert html =~ "live-#{n}"
        assert count(html, "live-#{n}") == 1
      end

      refute has_element?(alice_view, "#load-older")
    end
  end

  defp join_room(name) do
    {:ok, user} = Accounts.join(name)
    {:ok, view, _html} = build_conn() |> log_in(user) |> live(~p"/room")
    {user, view}
  end

  defp seed(user, n) do
    base = ~U[2026-01-01 00:00:00.000000Z]

    entries =
      for i <- 1..n do
        at = DateTime.add(base, i, :second)
        %{user_id: user.id, body: "seed-#{pad(i)}", inserted_at: at, updated_at: at}
      end

    Repo.insert_all(Message, entries)
  end

  defp pad(i), do: String.pad_leading(to_string(i), 3, "0")
  defp count(html, needle), do: length(String.split(html, needle)) - 1

  defp in_order(html, needles) do
    positions = Enum.map(needles, &(:binary.match(html, &1) |> elem(0)))
    positions == Enum.sort(positions)
  end
end
