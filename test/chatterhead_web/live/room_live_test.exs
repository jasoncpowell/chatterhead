defmodule ChatterheadWeb.RoomLiveTest do
  # async: false — CHAT-11 makes this LiveView track and observe presence, and
  # send_message/2 below broadcasts on a single global topic.
  use ChatterheadWeb.ConnCase, async: false

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.Scope
  alias Chatterhead.Chat
  alias Chatterhead.Chat.Message
  alias Chatterhead.Repo

  describe "guard" do
    test "a visitor with no session is redirected to the lobby", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/room")
    end

    test "a joined user reaches the room", %{conn: conn} do
      {:ok, user} = Accounts.join("roomie")

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      assert has_element?(view, "#messages")
    end
  end

  describe "history" do
    test "renders the most recent page oldest-first", %{conn: conn} do
      {:ok, user} = Accounts.join("historian")
      seed_messages(user, ~w(first second third))

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      html = render(view)
      positions = Enum.map(~w(first second third), &(:binary.match(html, &1) |> elem(0)))
      assert positions == Enum.sort(positions)
    end

    test "shows an empty state with no history", %{conn: conn} do
      {:ok, user} = Accounts.join("lonely")

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      assert render(view) =~ "No messages yet"
    end
  end

  describe "live fan-out" do
    test "a message broadcast on the room topic appears without a refresh", %{conn: conn} do
      {:ok, alice} = Accounts.join("alice-room")
      {:ok, bob} = Accounts.join("bob-room")

      {:ok, view, _html} = conn |> log_in(alice) |> live(~p"/room")

      {:ok, _} = Chat.send_message(Scope.for_user(bob), %{body: "ping from bob"})

      assert render(view) =~ "ping from bob"
    end

    test "a body containing HTML renders escaped", %{conn: conn} do
      {:ok, user} = Accounts.join("xss-tester")

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      {:ok, _} = Chat.send_message(Scope.for_user(user), %{body: "<script>alert(1)</script>"})

      html = render(view)
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "composing" do
    test "submitting persists the message and renders it for the sender", %{conn: conn} do
      {:ok, user} = Accounts.join("sender")
      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      view |> form("#message-form", message: %{body: "my first message"}) |> render_submit()

      assert render(view) =~ "my first message"
      assert Repo.aggregate(Message, :count) == 1
    end

    test "a blank body renders an error and persists nothing", %{conn: conn} do
      {:ok, user} = Accounts.join("blank-sender")
      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      html = view |> form("#message-form", message: %{body: "   "}) |> render_submit()

      assert html =~ "blank"
      assert Repo.aggregate(Message, :count) == 0
    end

    test "the composer clears after a successful send", %{conn: conn} do
      {:ok, user} = Accounts.join("clearer")
      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      html = view |> form("#message-form", message: %{body: "clear me"}) |> render_submit()

      refute html =~ ~s(value="clear me")
    end
  end

  describe "scroll hook" do
    test "the message pane is wired to the .MessageList colocated hook", %{conn: conn} do
      {:ok, user} = Accounts.join("scroller")

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      # Colocated hooks render with the module-qualified name; behaviour is
      # browser-only and verified manually.
      assert has_element?(view, ~s(#messages[phx-hook$="MessageList"]))
    end
  end

  describe "load older" do
    test "shows the control and prepends the previous page in order", %{conn: conn} do
      {:ok, user} = Accounts.join("pager")
      size = Chat.page_size()
      seed_n(user, size + 10)

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      html = render(view)
      assert has_element?(view, "#load-older")
      refute html =~ "msg-001"
      assert html =~ "msg-#{pad(size + 10)}"

      html = view |> element("#load-older") |> render_click()

      assert html =~ "msg-001"
      refute has_element?(view, "#load-older")
      assert pos(html, "msg-001") < pos(html, "msg-#{pad(size + 1)}")
    end

    test "no control when history is one page or less", %{conn: conn} do
      {:ok, user} = Accounts.join("shortpager")
      seed_n(user, Chat.page_size())

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      refute has_element?(view, "#load-older")
    end

    test "walks back through multiple pages; a message between loads is not lost or dupd", %{
      conn: conn
    } do
      {:ok, user} = Accounts.join("concurrent-pager")
      size = Chat.page_size()
      total = size * 2 + 5
      seed_n(user, total)

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

      view |> element("#load-older") |> render_click()

      {:ok, _} = Chat.send_message(Scope.for_user(user), %{body: "brand new"})
      assert render(view) =~ "brand new"

      html = view |> element("#load-older") |> render_click()

      for i <- 1..total, do: assert(html =~ "msg-#{pad(i)}")
      assert count(html, "brand new") == 1
      # the live message still appended at the very bottom
      assert pos(html, "brand new") > pos(html, "msg-#{pad(total)}")
      refute has_element?(view, "#load-older")
    end
  end

  defp seed_n(user, n), do: seed_messages(user, Enum.map(1..n, &"msg-#{pad(&1)}"))
  defp pad(i), do: String.pad_leading(to_string(i), 3, "0")
  defp pos(html, needle), do: :binary.match(html, needle) |> elem(0)
  defp count(html, needle), do: length(String.split(html, needle)) - 1

  defp seed_messages(user, bodies) do
    base = ~U[2026-01-01 00:00:00.000000Z]

    entries =
      for {body, i} <- Enum.with_index(bodies) do
        at = DateTime.add(base, i, :second)
        %{user_id: user.id, body: body, inserted_at: at, updated_at: at}
      end

    Repo.insert_all(Message, entries)
  end
end
