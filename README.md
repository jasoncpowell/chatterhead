# Chatterhead

A single-room live chat: pick a name, join, and talk. Everyone sees every message as
it's sent, and the roster shows who's in the room right now — going offline the
moment you close the tab, with no polling.

It's built on Phoenix LiveView with `Phoenix.PubSub` for message fan-out and 
`Phoenix.Presence` for presence. The reasoning behind the design — including the
 hings deliberately *not* built — is in [`docs/`](docs/) and summarised below.

- Elixir 1.20 / OTP 29 · Phoenix 1.8 · LiveView 1.2 · Ecto 3.14 · PostgreSQL 17

---

## Quickstart

Needs Docker (for Postgres) and the Elixir/OTP toolchain in
[`.tool-versions`](.tool-versions).

```sh
docker compose up -d --wait     # Postgres 17, credentials match the config
mix setup                       # deps, create + migrate DB, seed users, build assets
mix phx.server
```

Open <http://localhost:4000>, enter a name, and you're in the room.

### See presence and fan-out

Open a **second browser** — or a private/incognito window — and join as a different
name. Now:

- A message sent in one window appears in the other instantly.
- Each window's roster shows the other person move to **Online**.
- Close one window, or click **Leave**: the other shows that person go **Offline**
  immediately, with a "last seen" label.
- Open the room in two tabs as the same user: you stay online until *both* close.

There's a dev helper to fill the room with history so you can try "Load older":

```sh
mix run priv/repo/dev_seeds.exs   # ~60 messages; no-ops if the room isn't empty
```

---

## Running without Docker

`config/dev.exs` and `config/test.exs` expect Postgres on `localhost:5432` as user
`postgres` / password `postgres`. If your local Postgres differs, edit the
`username` / `password` / `hostname` / `port` there.

**Port 5432 collision.** If you already run Postgres (e.g. Postgres.app) on 5432,
either stop it, or remap the container: change `docker-compose.yml` to `"5433:5432"`
and add `port: 5433` to the `Chatterhead.Repo` config in `config/dev.exs` and
`config/test.exs`.

**`citext` privileges.** The first migration runs `CREATE EXTENSION citext`. The
container's `postgres` role is a superuser, so this is fine. A managed Postgres that
withholds extension-create rights would need a `lower(name)` functional unique index
instead — not built here.

---

## Running the tests

```sh
mix test                       # ~120 tests
mix test --exclude integration # skip the multi-connection suite for a faster loop
mix precommit                  # the full gate: compile --warnings-as-errors, format, test
```

CI runs `mix precommit`'s checks on every push and pull request
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

---

## Architecture

Two contexts own the domain; the web layer never touches `Repo` directly.

```
lib/chatterhead/
  accounts.ex                 join/1 (find-or-create), list_users/0, touch_last_seen/2
  accounts/user.ex            schema — citext name, changeset
  accounts/scope.ex           %Scope{user: %User{}} — identity through the web layer
  accounts/roster.ex          pure projection: users × online set → sorted entries
  accounts/roster/entry.ex    %Entry{id, name, online?, last_seen_at}
  chat.ex                     list_recent/1, list_before/2 (keyset), send_message/2, PubSub
  chat/message.ex             schema — body validation

lib/chatterhead_web/
  user_auth.ex                fetch_current_scope plug, on_mount hooks, log_in/out
  controllers/session_controller.ex   POST /join, DELETE /leave (cookie boundary)
  channels/presence.ex        Phoenix.Presence + presence client (init/1, handle_metas/4)
  live/lobby_live.ex          "/"     — join form + live roster (observes presence)
  live/room_live.ex           "/room" — streamed history, composer, live roster (tracks)
  components/chat_components.ex   status dot, roster, message row, "last seen" label
```

### Three topics — kept separate on purpose

| Topic | Published by | Subscribed by | Payload |
|---|---|---|---|
| `"chat:room"` | `Chat.send_message/2` | both LiveViews | `{:new_message, %Message{user: %User{}}}` |
| `"chat:presence"` | `Phoenix.Tracker` (internal) | **nobody** | raw `presence_diff` |
| `"chat:presence:events"` | `Presence.handle_metas/4` | both LiveViews | `{:user_online, ...}` / `{:user_offline, ...}` |

`Phoenix.Presence` broadcasts a raw diff to whatever topic you `track/4` on. If the
LiveViews subscribed to that, every diff would land in their `handle_info/2`. Instead
the **presence client** (`handle_metas/4`) consumes the raw diffs and re-broadcasts
*semantic* events on a separate topic — so the LiveViews never see Presence's data
shape.

### The message path

```
RoomLive "send" → Chat.send_message(%Scope{}, attrs)
              → Repo.insert
              → PubSub.broadcast({:new_message, message})   (user preloaded)
              → every subscriber's handle_info → stream_insert   (incl. the sender)
```

The broadcast comes from the context, not the LiveView, so an IEx session or a future
HTTP endpoint also fans out. The sender has **no local echo** — they receive their
own message through the broadcast like everyone else, so there is one code path and
one ordering everywhere.

### The presence path

```
RoomLive.mount → Presence.track_user(self(), user)
             → Phoenix.Tracker diff
             → Presence.handle_metas/4  (holds the online set as process state)
                 → local_broadcast({:user_online | :user_offline, ...})
                 → supervised Task → Accounts.touch_last_seen/2   (on leave)
             → every subscriber's handle_info → Roster.mark_online/2 or mark_offline/2
```

"Online" means *the presence key exists* — not that the meta list has length one — so
a second tab is silent, and closing one of two tabs is silent. On leave, `last_seen_at`
is persisted from a supervised task so a slow write never blocks the tracker, using
the same second-truncated timestamp the event carried.

### Going offline promptly

Presence is released when the LiveView process dies, and that happens when its
connection goes away — so on its own, "who is online" is only as prompt as the
browser's goodbye, and a browser unloading a page is not a dependable narrator of
that. `phoenix.js` defers its WebSocket close behind a `setTimeout` when the send
buffer is not empty and timers stop running mid-unload; on the long-poll fallback
the goodbye is an XHR the browser cancels; a page frozen into the back/forward
cache is never torn down at all. When the goodbye is lost, nothing releases the
presence until the transport's own silence timer expires, tens of seconds later.

So departure is not inferred from the connection. There are three paths, in order
of how much they trust the client:

| Path | Mechanism | Covers |
| --- | --- | --- |
| **Leave** | `UserAuth.log_out_user/1` broadcasts `"disconnect"` on the session's `live_socket_id` | Every tab, no client involvement — the server knows |
| **Page unload** | `pagehide` → `navigator.sendBeacon("/away")` → `Presence.untrack_page/2` | Tab/window close and navigation, on either transport |
| **Silence** | WebSocket `timeout` / long-poll `window_ms` in `endpoint.ex` | A client that vanishes without a word: a crash, a kill, a dropped network |

The beacon names the *page*, not the user: a page mints an id at load and sends it
as a connect param, and it rides along in the presence meta. A beacon still in
flight for the page being left therefore cannot unseat the page being navigated
to, which holds a different id.

---

## Design decisions

- **`Phoenix.Presence`, not a hand-rolled monitor `GenServer`.** A `Map` of
  `user_id → pid` with `Process.monitor/1` looks like OTP knowledge; reaching for the
  CRDT-based, distributed tracker that already does monitor-and-cleanup is the actual
  senior move. *Honest caveat:* its resilience is about multi-node behaviour. On a
  single node, if the tracker crashes, local presence state is lost and live
  LiveViews are not re-tracked. Accepted for this exercise.

- **A presence *client*, at a documented extension point.** `handle_metas/4` is real
  process work — state, callbacks, supervised side effects — done where the library
  invites it, rather than in place of the library. It buys: one place to compute the
  roster, LiveViews decoupled from Presence's data shape, and a natural hook for
  persisting `last_seen_at`.

- **No room process.** For one global room whose source of truth is Postgres, a
  `GenServer` per room adds a serialization point, a crash-recovery problem, and a
  second place message ordering can disagree with the database — for no correctness
  gain. It would earn its keep with per-room state that *shouldn't* hit the database:
  typing indicators, per-room rate limiting, an in-memory ring buffer, or many rooms
  with skewed traffic. None are requirements.

- **`citext` for names**, so "Jason" and "jason" are one user with no `lower(name)` at
  any call site. Costs extension-create privileges (see above).

- **`:utc_datetime_usec` on messages.** The generator default truncates to whole
  seconds; two messages in the same second would tie, and a chat log that reorders on
  reload is exactly the bug this kind of exercise looks for. Ordering is always by
  `[inserted_at, id]` so ties stay deterministic regardless.

- **Keyset pagination, not offset.** `OFFSET` is defined against a result set that
  shifts on every insert, so paging back under a live chat duplicates or skips
  messages. `(inserted_at, id) < cursor` is anchored to a row; the composite index
  makes it a range scan whose cost doesn't grow with how far back you page.

- **Streams for messages, a plain assign for the roster.** An unbounded message list
  in socket assigns is a per-connection memory leak. The roster is bounded by user
  count and needs sorting and online/offline partitioning on every change, which
  streams actively obstruct.

- **Identity via a cookie set by a plain controller.** A LiveView runs over a
  WebSocket and can't set a cookie, so joining is a full-page `POST /join`. The payoff
  is that identity survives a refresh, the back button, and a second tab.

---

## Requirements

| # | Requirement | Where |
|---|---|---|
| A1 | Landing page lists **all** users, including never-online | `Accounts.list_users/0` → `Roster` → `LobbyLive` |
| A2 | Online/offline derives from live connections, not a DB flag | `Presence` → `Roster` |
| A3 | Enter a name to join; find-or-create; no auth | `Accounts.join/1`, `SessionController` |
| A4 | Joined visitor enters one shared room | `RoomLive` at `/room` |
| A5 | Room shows **all** past messages | `Chat.list_recent/1` + `list_before/2` + `#load-older` |
| A6 | Room shows users + status, live | `RoomLive` roster + presence events |
| A7 | New messages appear for all and persist | `Chat.send_message/2` → insert + broadcast |
| A8 | Presence managed dynamically — closing a tab flips you offline | `Phoenix.Presence`, process lifecycle |

---

## Assumptions

- **One global room.** No room creation, listing, or DMs.
- **A name is an unverified identity claim** — anyone can claim any existing name. A
  deliberate, accepted consequence of "no authentication required," not an oversight.
- Names are unique **case-insensitively**, trimmed, internal whitespace collapsed,
  1–24 characters, no control characters.
- **"Online" means present in the room.** A joined user browsing the lobby is not
  counted as online. `last_seen_at` means "last went offline" — `join/1` never writes
  it.
- **Message ordering is by database timestamp**, not the client clock.
- No editing, deleting, typing indicators, read receipts, attachments, or search.
- Single-node in development. The design is multi-node-safe as written (Presence CRDT +
  PubSub), and `DNSCluster` is in the supervision tree.
- Session identity has no expiry (`max_age`).

## Known limitations

- **Single-node presence resilience.** If the tracker process crashes, local presence
  state is lost and live LiveViews are not automatically re-tracked.
- **Relative "last seen" labels don't tick.** A LiveView only re-renders on a change,
  so "2m ago" stays "2m ago" until the next roster event. Message timestamps are
  absolute for this reason.
- **Loaded history stays in the client DOM.** Streams bound *server-side* memory
  regardless of message count, but every message paged in is still rendered in the
  browser. `phx-viewport-top` infinite scroll and a windowed DOM are the production
  upgrades.
- **Abrupt disconnects.** A cleanly-closed tab drops you offline in about a second. A
  crash / kill / dropped network is detected when the WebSocket times out — tuned down
  to ~25s here (from the 60s default).