# Chatterhead — Architecture Options

**Status:** exploration / pre-implementation
**Date:** 2026-08-28
**Purpose:** Survey the reasonable ways to build the take-home chat app, name the decisions that matter, and pick a direction. This is *not* the implementation plan — it is the input to it.

---

## 1. What the exercise actually asks for

The original brief is **not committed to this repo.** It should be added as `docs/00-brief.md` so this decoding can be checked against the source; until then everything in this section is the author's paraphrase and carries that risk.

Decoded into acceptance criteria:

| # | Requirement | Concrete criterion |
|---|---|---|
| A1 | Landing page lists **all users** | Users persisted in Postgres are listed, including users who have never been online this boot |
| A2 | Each user's **online/offline** status | Status derives from live connections, not a DB boolean |
| A3 | Visitor **enters a name** to join, no auth | Find-or-create by name; no password |
| A4 | Joined visitor enters a **shared room** | One global room; everyone sees everyone |
| A5 | Room shows **all past messages** | Every prior message loaded from Postgres on mount, oldest-first — not a capped window (see §4, Axis 6) |
| A6 | Room shows **users + status** | Same roster as A1, live-updating |
| A7 | New messages **appear for all users** and **persist** | Insert then fan-out; every connected client re-renders without a refresh |
| A8 | Presence managed **dynamically** | Closing the tab flips you offline with no user action and no polling |

Two meta-requirements carry real weight in grading and are easy to under-serve:

- **"Demonstrates your understanding of OTP concepts."** The trap here is to prove it by hand-rolling something Phoenix already gives you. See §4.
- **"Design clarity"** and **"show your work."** The README's *rationale* — including things deliberately **not** built — is graded alongside the code.

The exercise also says aesthetics are not the focus. Note this conflicts with `AGENTS.md` in this repo (inherited from `phx.new`), which instructs "world-class UI." Flagged as an open question in §11.

---

## 2. What we are starting from

Verified against the current scaffold:

- Elixir 1.20.4 / OTP 29 (`mix.exs` declares `~> 1.17`)
- Phoenix **1.8.13**, LiveView **1.2.11**, Ecto SQL **3.14.0**, Postgrex 0.22.4, Bandit 1.12.5
- `Phoenix.PubSub` already supervised as `Chatterhead.PubSub` ([application.ex:14](lib/chatterhead/application.ex#L14)); endpoint already wired to it
- Tailwind v4 + daisyUI available; `core_components.ex` provides `<.input>`, `<.button>`, `<.flash>`, `<.icon>` — and is itself built on daisyUI classes (see §11, Q2)
- `Layouts.app` declares an optional `current_scope` assign ([layouts.ex:30](lib/chatterhead_web/components/layouts.ex#L30)), but its render body never reads it and no `phx.gen.auth` scope plumbing exists — so there is no scope convention already "in play" to satisfy. Adding a minimal scope is forward-compat and design-clarity polish, not a layout requirement (see §4, Axis 4)
- **No** `phx.gen.auth`, no contexts, no schemas, no Presence module yet
- `priv/repo/seeds.exs` is empty — the plan should seed a handful of users so the lobby isn't blank on first boot and A1's "users who have never been online" is demonstrable without a second browser
- Postgres.app is installed but was **not accepting connections** at check time (`pg_isready` → no response on `/tmp:5432`). Needs to be running before `mix setup` (and before `mix test` — the `test` alias runs `ecto.create` / `ecto.migrate`)

Everything below assumes we add code, not that we regenerate the app.

---

## 3. Decisions that are not really open

These are the same across every plan. Listing them here keeps the plans in §5 differing only where they genuinely differ.

1. **Two contexts.** `Chatterhead.Accounts` (users) and `Chatterhead.Chat` (messages, room fan-out). The web layer never touches `Repo` directly.
2. **`Phoenix.PubSub` for fan-out**, one topic for the room (a `@topic` module attr in `Chat`, shared by message broadcasts and the presence-diff subscription). Already supervised.
3. **`Phoenix.Presence` for presence** — not a hand-rolled tracker. Rationale in §4.
4. **LiveView streams for the message list.** Required by the repo's own guidelines and correct on the merits: an unbounded `@messages` list in socket assigns is a memory leak per connection. The **roster** stays a plain assign — it is bounded by user count, and it needs sorting and online/offline partitioning on every change, which streams actively obstruct (they are not enumerable, so any reordering means re-streaming the whole collection with `reset: true`). (Note `AGENTS.md`'s stream cheatsheet has a bug — it labels `at: -1` as "prepend" when it appends; see §4, Axis 6 — so don't let it "correct" the message-ordering plan.)
5. **Ecto changesets for all validation**, with a DB-level unique index backing the name uniqueness (not just a changeset check).
6. **Session cookie for identity.** A LiveView *cannot* write the session cookie, which forces a small architectural decision — see §4, Axis 4.
7. **`live_session` + `on_mount`** to load the current user once from the session and assign it (as a small `Scope` struct — see §4, Axis 4), so both LiveViews agree on who you are without each re-reading the session.
8. **Tests via `Phoenix.LiveViewTest`**, including at least one test with two simultaneous connections proving cross-client updates.

---

## 4. The axes that actually differentiate designs

### Axis 1 — Presence: built-in vs. hand-rolled

The tempting move on an "OTP concepts" exercise is to write a `GenServer` holding `%{user_id => pid}`, `Process.monitor/1` each LiveView, and remove on `:DOWN`. It works on one node and it looks like OTP knowledge.

It is the wrong answer, and saying why *is* the OTP knowledge:

- `Phoenix.Presence` is built on `Phoenix.Tracker`, a **CRDT-based, eventually-consistent, distributed** tracker. It survives netsplits and heals on reconnect; a `Map` in a single GenServer does neither.
- It already does the `Process.monitor` + `:DOWN` cleanup, so the "dynamic" requirement (A8) is satisfied by process lifecycle, not by a heartbeat.
- A single GenServer is a serialization point and a single point of failure for the whole app's presence.

One honest caveat, since the pitch above leans on resilience: those properties are about *multi-node* behaviour. On a single node, if the tracker process crashes, local presence state is lost and live LiveViews are not automatically re-tracked. Accepted for this exercise (noted in §10) — just don't oversell it in the README.

Reaching for a well-designed OTP library **is** the senior move; reimplementing it badly is the junior one. The README should say this explicitly.

**Where does the Presence module live?** `mix phx.gen.presence` defaults to `ChatterheadWeb.Presence`. Keep that: tracking is bound to *connection* lifecycle, which is a web concern, and it keeps the dependency arrow pointing inward (web → domain). The domain then exposes a pure function that combines a user list with an online-id set, so the contexts never know Presence exists.

### Axis 2 — Where presence knowledge is assembled

| Option | How it works | Trade-off |
|---|---|---|
| **2a — Each LiveView handles diffs** | Every LiveView subscribes to the topic and pattern-matches `%Phoenix.Socket.Broadcast{event: "presence_diff"}`, then calls `Presence.list/1` to recompute | Fewest moving parts. Every LiveView re-does the same computation and knows Presence's data shape (`%{key => %{metas: [...]}}`) |
| **2b — Presence client process** | The Presence module implements the optional `init/1` + `handle_metas/4` callbacks, keeps the canonical online set as process state, and re-broadcasts *semantic* events like `{:user_online, user}` / `{:user_offline, user}` | A **documented, first-class Phoenix pattern** (see `Phoenix.Presence` moduledoc, "Using Elixir as a Presence Client") — real OTP without reinvention. Gives one place to compute the roster and one hook point for persisting `last_seen_at`. Costs a singleton process that is global across async tests |

2b is the honest way to show OTP depth here: it is an OTP process doing something the library explicitly invites you to do, not a replacement for the library.

Either way, a LiveView that mounts *after* people are already online needs an **initial snapshot** (`Presence.list/1` in 2a; a snapshot call into the client process in 2b) to seed its roster before it starts applying join/leave deltas — the diff stream alone never replays existing presences.

### Axis 3 — Is there a room process?

| Option | Shape |
|---|---|
| **3a — No room process** | LiveViews call `Chat.send_message/2`; the context inserts and broadcasts. Postgres is the only source of truth |
| **3b — `Chat.Room` GenServer** | `DynamicSupervisor` + `Registry` (`{:via, Registry, {Chatterhead.RoomRegistry, room_id}}`), each room a process owning a bounded in-memory buffer of recent messages, write-through to Postgres, broadcasting to subscribers |

3b is the flashiest OTP demonstration and the most likely to be read as over-engineering. For **one** global room whose source of truth is Postgres, it adds a serialization point, a crash-recovery problem (rebuild the buffer from the DB on restart), and a second place where message ordering can disagree with the database — for zero correctness gain.

A room process earns its keep when there is per-room state that *shouldn't* hit the database: typing indicators, per-room rate limiting, ephemeral "N unread" counters, an in-memory ring buffer that spares a DB read on every mount, or many rooms with skewed traffic. None of those are requirements.

**Recommendation:** 3a, and use the README to explain the conditions under which 3b becomes correct. That reads as judgment; building 3b unprompted reads as pattern-matching on the word "OTP".

### Axis 4 — Identity and the session

A LiveView runs over a WebSocket and **cannot set a cookie**. That single fact drives the join flow.

| Option | Flow | Trade-off |
|---|---|---|
| **4a — Controller join** (recommended) | Lobby form `POST`s to `SessionController.create` → `Accounts.join(name)` → `put_session(:user_id, id)` → `redirect(to: ~p"/room")`. `on_mount` reads the session and assigns the scope | Identity survives refresh, back button, and a second tab. ~15 lines. Standard Phoenix |
| **4b — LiveView-only** | Name lives in LiveView assigns; `push_patch` to the room view | Fewest files, but refresh drops you out of the room and you can't demo two tabs as the same user. A reviewer will notice |
| **4c — Token in the URL** | `/room?as=<signed token>` | Shareable identity in a URL is worse than a cookie in every way |

4a. The extra controller is small and it is what makes the "open two browser windows" demo behave sanely. The lobby form is a plain full-page `POST` (not `phx-submit`) — `<.form for={@form} action={~p"/join"}>` renders the CSRF token automatically once `:action` is set.

Alongside it, define a minimal `Chatterhead.Accounts.Scope` struct (`%Scope{user: %User{}}`) mirroring what `phx.gen.auth` generates in 1.8. Nothing in the current scaffold *requires* this — the stock `Layouts.app` never reads `@current_scope` — but it gives future authorization one obvious place to live and matches the convention a 1.8 reviewer expects. If it starts to feel like ceremony, threading the bare `%User{}` is a fine downgrade.

### Axis 5 — One LiveView or two?

- **5a — `LobbyLive` (`/`) + `RoomLive` (`/room`)**, both inside one `live_session`. Maps 1:1 to the two screens in the spec; navigation via `<.link navigate=...>` reuses the socket.
- **5b — one `ChatLive`** with a `@joined?` flag.

5a. Two focused LiveViews read better than one branching on state, and the URL then reflects where you are.

### Axis 6 — Loading message history

A5 says **all** past messages. Two ways to honour that:

| Option | How | Trade-off |
|---|---|---|
| **6a — Load everything** (recommended) | `list_history/0` ordered `[asc: :inserted_at, asc: :id]` on mount, `stream/3` the lot | Literally satisfies A5. Streams bound *server-side assigns* regardless of count — but every message is still rendered into the client DOM and shipped in the first payload, so the client cost is bounded by data volume, not by using streams. At take-home volumes (seeded users + a demo conversation) that payload is trivial |
| **6b — Windowed + "load older"** | Most recent 50 on mount, then keyset pagination on `{inserted_at, id}`, prepending older pages with `stream_insert(:messages, msg, at: 0)` | The production answer once the table is large. But A5 is then only met if the "load older" control is actually built and wired — deferring it to a "stretch goal" means shipping something that fails A5 |

**Recommendation: 6a.** Add the "load older" control (6b) only if you also want to demonstrate keyset pagination — and if you do, it is in scope, not a stretch. Whichever way: new arrivals append (`stream_insert/4` defaults to `at: -1`; `at: 0` is what prepends — `AGENTS.md`'s cheatsheet has this backwards). Offset pagination is wrong regardless — new inserts shift the window. And if `stream`'s `:limit` option is ever used to cap the rendered list, note it is *not* enforced on the first `mount/3` render — the fix is to load fewer rows, not to lean on the limit.

---

## 5. Plan overviews

### Plan A — Idiomatic Minimal *(the honest ~2-hour build)*

Axes: 2a · 3a · 4a · 5a.

```
Chatterhead.Accounts          User schema, join/1, list_users/0
Chatterhead.Accounts.Scope    %Scope{user: user}
Chatterhead.Chat              Message schema, list_history/0, send_message/2,
                              @topic, subscribe/0, broadcast on success
ChatterheadWeb.Presence       use Phoenix.Presence
ChatterheadWeb.SessionController  join → put_session → redirect
ChatterheadWeb.LobbyLive      roster + join form
ChatterheadWeb.RoomLive       track presence, stream messages, compose form
```

Also: seed a few users in `priv/repo/seeds.exs` so the lobby and offline states are visible on a fresh DB.

Message path: `RoomLive` `handle_event("send", ...)` → `Chat.send_message/2` → `Repo.insert` → `PubSub.broadcast({:new_message, message})` → every subscribed LiveView (**including the sender's**) `handle_info` → `stream_insert`.

Presence path: `RoomLive.mount` (only when `connected?/1`) → `Presence.track(self(), @topic, user_id, %{name: name, online_at: ...})` → seed roster from `Presence.list/1` → tracker broadcasts `presence_diff` on later changes → each LiveView recomputes the roster.

- **Strengths:** small, obviously correct, every line justified. All eight acceptance criteria met.
- **Weakness:** a reviewer hunting for bespoke process code finds none. Mitigated only by the README arguing the point.
- **Effort:** ~2 hours.

### Plan B — Idiomatic Minimal + Presence Client *(recommended)*

Plan A, plus:

1. A `Task.Supervisor` added to the application supervision tree (needed by point 3).
2. `ChatterheadWeb.Presence` implements `init/1` and `handle_metas/4`, holding the online-user set as process state and broadcasting semantic `{:user_online, user}` / `{:user_offline, user}` events. LiveViews subscribe to *those* instead of decoding raw presence diffs, and still seed their roster from a snapshot on mount (Axis 2).
3. That same callback is the natural place to persist `last_seen_at` on the user row — via `Task.Supervisor.start_child/2` so a slow write never blocks the tracker — giving offline users a meaningful "last seen" instead of a bare "offline".

- **Strengths:** genuine OTP surface (process state, supervised side-effect tasks, callback-driven lifecycle) using patterns Phoenix documents. Decouples LiveViews from Presence's data shape. Produces a visibly better UI for free.
- **Costs:** ~45–90 minutes more. The presence client is a singleton with global state, so tests touching it must be `async: false` — which, with this scaffold's sandbox setup, also puts the Repo in shared mode, and *that* is what lets the unowned `last_seen_at` task find a connection (see §8).
- **Effort:** ~3–3.5 hours.

### Plan C — Room as a Process

Plan B, plus Axis 3b: `Chat.RoomSupervisor` (DynamicSupervisor) + `Chat.RoomRegistry` + `Chat.Room` GenServer per room, holding a bounded recent-message buffer and rebuilding from Postgres on start.

- **Strengths:** the fullest OTP showcase — supervision strategy, dynamic supervision, `:via` registration, process state recovery, `handle_continue` for post-init loading. Multi-room becomes a routing change.
- **Costs:** highest bug surface for the least requirement coverage. Needs a defensible answer for "what happens when the room process crashes mid-write?" and "why is this faster than Postgres?" — and for a single room the honest answer to the second is "it isn't."
- **When to choose it:** only if you want the interview conversation to center on supervision trees, and you have time to make it genuinely correct. Half-built, it is worse than Plan A.

---

## 6. Recommendation

**Plan B**, with Plan C's design documented but not built.

The rationale scales beyond the exercise: the requirements are satisfied by Plan A, so anything past it must justify itself. Plan B's addition justifies itself twice — it uses a documented extension point rather than replacing library behavior, and it buys a real feature (`last_seen_at`). Plan C's addition does not, at one room.

Cut line if time runs short: drop `last_seen_at` persistence first (keeps the presence client, drops the `Task.Supervisor` and the sandbox wrinkle). Dropping the presence client itself is a bigger step down — every LiveView's `handle_info` goes back to decoding raw `presence_diff` — but still a bounded change, not a rewrite.

---

## 7. Data model sketch

```elixir
# users
add :name, :citext, null: false        # citext ⇒ case-insensitive uniqueness for free
add :last_seen_at, :utc_datetime       # Plan B only
timestamps(type: :utc_datetime)
create unique_index(:users, [:name])

# messages
add :body, :text, null: false
add :user_id, references(:users, on_delete: :delete_all), null: false
timestamps(type: :utc_datetime_usec)   # note the precision, see below
create index(:messages, [:inserted_at, :id])
```

Three decisions worth arguing in the README:

1. **`citext`** (requires `CREATE EXTENSION citext` in the migration) so "Jason" and "jason" are one user. The schema field is still `field :name, :string` — citext only changes comparison semantics in Postgres. The alternative is a `lower(name)` functional unique index plus normalization in the changeset; citext is less code and harder to bypass, at the cost of needing extension-create privileges (fine on local Postgres.app; the `lower(name)` index is the portable fallback if a managed environment withholds them).
2. **`:utc_datetime_usec` on messages.** The scaffold's generator default is `:utc_datetime`, which truncates to **whole seconds** — two messages sent in the same second would tie, and a chat log that reorders on reload is exactly the kind of bug this exercise is looking for. This has to be set in *both* the migration column and the schema's `timestamps/1` call, or the precision won't round-trip. Regardless of precision, order by `[asc: :inserted_at, asc: :id]` so ties are still deterministic.
3. **No `rooms` table.** One global room is a spec assumption, not an oversight; the README should say what adding rooms would touch (`messages.room_id`, topic per room, roster scoped per room).

---

## 8. Cross-cutting concerns and known traps

Each of these is a place where a working-looking implementation is subtly wrong.

**`mount/3` runs twice.** Once for the dead HTTP render, once over the WebSocket. `Presence.track` and `PubSub.subscribe` must be guarded by `if connected?(socket)`, or you track a process that is about to die.

**Multi-tab presence.** Track keyed by `user_id` (Presence casts the key to a **string**, so the roster's pure function must compare against strings). Each connection adds a *meta* under that key. "Online" means the key exists, **not** that the meta list has length 1. Closing one of two tabs must not show you as offline. Untracking on exit is automatic — the LiveView needs no `terminate/2` cleanup for it.

**Roster = database LEFT JOIN presence.** All users come from Postgres; the online set comes from Presence. Keep this as a pure function (`Roster.build(users, online_ids)`) so it is trivially testable without a socket.

**Put `name` in the presence meta.** It avoids implementing `fetch/2`, avoids an N+1 on every diff, and — importantly — keeps the DB out of Presence's fetcher processes, which sidesteps the sandbox problem below.

**Presence is not sandboxed.** Presence and PubSub are global, application-wide processes; `Ecto.Adapters.SQL.Sandbox` isolation does not extend to them. If any presence-triggered code touches the DB (`fetch/2`, or Plan B's `last_seen_at` write), it runs in a process that does not own a checked-out connection → ownership errors or flakes. Mitigations: keep presence DB-free (above — `name` in the meta, no `fetch/2`), and run the LiveView/presence tests `async: false`. This scaffold's `DataCase.setup_sandbox` uses `shared: not tags[:async]`, so `async: false` already puts the Repo in shared mode — which is what lets the unowned `last_seen_at` task find a connection, with no explicit `Sandbox.allow/3` needed unless you insist on `async: true`. `Phoenix.Presence` also exposes `fetchers_pids/0` (verified present in the vendored 1.8.13 source) so tests can drain fetcher processes in `on_exit`.

**Broadcast from the context, after the insert succeeds.** Broadcasting from the LiveView means an IEx session or a future API endpoint silently doesn't notify anyone. Broadcast the fully-loaded struct (user preloaded) so subscribers render without re-querying — otherwise every new message causes one query per connected client.

**No local echo.** Let the sender receive their own message through PubSub like everyone else. One code path, guaranteed consistent ordering, no duplicate-render bugs. The added latency is a round trip to a local process.

**Find-or-create is a race.** Two visitors submitting the same brand-new name concurrently will both see "no such user" and both insert. `Repo.insert(changeset, on_conflict: :nothing, conflict_target: :name)` followed by a re-fetch (the returned struct has a `nil` id on conflict), or catching the unique-constraint violation via `unique_constraint/2` and retrying the lookup. Handling this is cheap and is exactly the kind of correctness detail being graded.

**Validate the message.** Reject empty/whitespace-only bodies, cap length. HEEx escapes by default — never reach for `raw/1`.

**Re-stream on assign changes.** If a roster or edit-state assign changes what a *streamed* item renders, the item must be re-inserted; streams don't re-render from assigns.

**Scroll-to-bottom** needs a small JS hook (with a unique DOM id). Optional, and cosmetic — deferrable.

---

## 9. Testing strategy

Roughly in value order:

1. `Accounts.join/1` — creates on first use, returns the existing user on second, case-insensitive, handles the concurrent-insert race.
2. `Chat` — insert + validation rejections, `list_history/0` ordering (specifically the same-second tie case), preloads present.
3. Roster pure function — online/offline partitioning with no socket involved (feed it string ids to match what Presence emits).
4. `LobbyLive` — renders known users with correct status; submitting the join form redirects with a session set.
5. `RoomLive` — **the test that proves the feature**: two `live/2` connections (each with its own session via `init_test_session/2`), send from one, assert the other renders it. Same shape for presence: the second connection appears in the first's roster.

For (5), remember `Phoenix.Tracker` is eventually consistent — assert with a retry / `assert_receive` helper rather than a bare `render/1` immediately after connecting, or the test will flake on CI and pass locally. (PubSub message fan-out is not subject to the same lag; the caveat is specifically about presence.)

---

## 10. Assumptions to record in the README

- One global room; no room creation, listing, or DMs.
- A name is an identity claim with no verification — **anyone can claim any existing name.** Called out as a deliberate, accepted consequence of "no authentication required," not an oversight.
- Names are unique case-insensitively; whitespace trimmed; length bounded.
- The room loads the **full** message history on mount (§4, Axis 6); keyset pagination is the answer when the table outgrows that, and its absence is a scale note, not a dropped requirement.
- No edit, delete, typing indicators, read receipts, or attachments.
- Single-node in development. The design is multi-node-safe as written (Presence CRDT + PubSub) and `DNSCluster` is already in the supervision tree — but on a single node a tracker-process crash loses local presence state and does not re-track live LiveViews. Accepted for the exercise.
- Message ordering is by database timestamp, not client clock.

---

## 11. Open questions

1. **Which plan?** A (fastest, most defensible minimalism), B (recommended), or C (maximum OTP surface, maximum risk).
2. **UI effort.** The spec says aesthetics don't matter; this repo's `AGENTS.md` says "world-class UI." Note the two `AGENTS.md` rules — "**always** use the imported `<.input>` component from `core_components.ex`" (line 17) and "**always** manually write your own tailwind-based components instead of using daisyUI" (line 33) — already contradict each other, since the stock `core_components.ex` is built on daisyUI classes (`btn`, `alert`, `toast`, `fieldset`) and `app.css` loads the daisyUI plugin. That tension is inherited, not created here. A clean, restrained interface built on the components that ship is probably the right read of both; decide separately whether to invest in front-end craft, which changes the time budget.
3. **Time budget.** Submitting close to the stated ~2 hours is itself a signal about scope discipline. Is the goal to land near it, or to build the better artifact and note the actual time in the README?
4. **`last_seen_at`** — worth a `Task.Supervisor` plus `async: false` on the presence tests for a nicer offline state, or cut?
5. **Presence module namespace** — `ChatterheadWeb.Presence` (generator default, recommended) or `Chatterhead.Presence` if presence is treated as domain state.
6. **Commit the brief?** §1 is a paraphrase until `docs/00-brief.md` exists.

---

## 12. Suggested commit sequence

The exercise grades commit history, so the sequence should read as incremental progress rather than one dump:

1. `docs: capture architecture options and design decisions` *(this file)*
2. `docs: implementation plan`
3. `feat: add Accounts context with User schema and join/1`
4. `feat: seed initial users`
5. `feat: add Chat context with Message schema and full-history query`
6. `feat: add PubSub fan-out for new messages`
7. `feat: add Presence tracking and supervision wiring`
8. `feat: add SessionController and scope on_mount`
9. `feat: add LobbyLive with user roster and join form`
10. `feat: add RoomLive with streamed history and live updates`
11. `feat: broadcast semantic presence events via presence client` *(Plan B)*
12. `test: cross-client message and presence coverage`
13. `docs: README with setup, assumptions, and architecture`

`SessionController` lands before `LobbyLive` (step 8 before 9) because the lobby form posts to its route.

`AGENTS.md` is already in the repo and is the "AI instructions markdown file" the exercise encourages submitting — worth mentioning in the README rather than leaving it to be discovered.
