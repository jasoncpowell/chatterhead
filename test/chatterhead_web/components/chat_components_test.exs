defmodule ChatterheadWeb.ChatComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Chatterhead.Accounts.Roster.Entry
  alias ChatterheadWeb.ChatComponents

  describe "status_dot/1" do
    test "labels online and offline distinctly" do
      assert render_component(&ChatComponents.status_dot/1, online?: true) =~
               ~s(aria-label="online")

      assert render_component(&ChatComponents.status_dot/1, online?: false) =~
               ~s(aria-label="offline")
    end
  end

  describe "roster/1" do
    setup do
      entries = [
        %Entry{id: 1, name: "alice", online?: true},
        %Entry{id: 2, name: "Bob", online?: false, last_seen_at: nil},
        %Entry{id: 3, name: "carol", online?: false, last_seen_at: ~U[2026-01-01 00:00:00Z]}
      ]

      html =
        render_component(&ChatComponents.roster/1,
          entries: entries,
          counts: %{online: 1, offline: 2},
          current_user_id: 1
        )

      %{doc: LazyHTML.from_fragment(html), html: html}
    end

    test "gives each entry a stable id and a data-online attribute", %{doc: doc} do
      assert Enum.any?(LazyHTML.query(doc, "#roster-user-1[data-online='true']"))
      assert Enum.any?(LazyHTML.query(doc, "#roster-user-2[data-online='false']"))
      assert Enum.any?(LazyHTML.query(doc, "#roster-user-3[data-online='false']"))
    end

    test "renders online entries before offline entries", %{doc: doc} do
      ids =
        doc
        |> LazyHTML.query("li[id^='roster-user-']")
        |> LazyHTML.attribute("id")

      assert ids == ~w(roster-user-1 roster-user-2 roster-user-3)
    end

    test "marks the current user", %{html: html} do
      assert html =~ "(you)"
    end

    test "shows the section counts", %{html: html} do
      assert html =~ "Online (1)"
      assert html =~ "Offline (2)"
    end

    test "labels a never-online user as never joined", %{html: html} do
      assert html =~ "Never joined"
    end
  end

  describe "message/1" do
    setup do
      %{
        message: %{
          id: 1,
          user_id: 7,
          user: %{name: "alice"},
          body: "hi <script>alert(1)</script>",
          inserted_at: ~U[2026-01-02 14:32:05Z]
        }
      }
    end

    test "renders the author, body text, and an HH:MM timestamp", %{message: message} do
      html = render_component(&ChatComponents.message/1, message: message, current_user_id: nil)

      assert html =~ "alice"
      assert html =~ "14:32"
      assert html =~ ~s(title="2026-01-02 14:32:05 UTC")
    end

    test "escapes HTML in the body", %{message: message} do
      html = render_component(&ChatComponents.message/1, message: message, current_user_id: nil)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "tints only the current user's own message", %{message: message} do
      own = render_component(&ChatComponents.message/1, message: message, current_user_id: 7)
      other = render_component(&ChatComponents.message/1, message: message, current_user_id: 99)

      assert own =~ "bg-base-200"
      refute other =~ "bg-base-200"
    end

    test "wires the timestamp to the .LocalTime colocated hook", %{message: message} do
      html = render_component(&ChatComponents.message/1, message: message, current_user_id: nil)

      # Colocated hooks render with the module-qualified name; behaviour is
      # browser-only and verified manually.
      assert html =~ ~s(phx-hook="ChatterheadWeb.ChatComponents.LocalTime")
      assert html =~ ~s(id="message-time-1")
    end
  end

  describe "last_seen_label/1" do
    test "nil reads as never joined" do
      assert ChatComponents.last_seen_label(nil) == "Never joined"
    end

    test "renders a relative string for seconds, minutes, hours, and days ago" do
      now = DateTime.utc_now()

      assert ChatComponents.last_seen_label(DateTime.add(now, -30, :second)) == "just now"
      assert ChatComponents.last_seen_label(DateTime.add(now, -5, :minute)) == "5m ago"
      assert ChatComponents.last_seen_label(DateTime.add(now, -3, :hour)) == "3h ago"
      assert ChatComponents.last_seen_label(DateTime.add(now, -30, :hour)) == "yesterday"
      assert ChatComponents.last_seen_label(DateTime.add(now, -5, :day)) == "5d ago"
    end
  end
end
