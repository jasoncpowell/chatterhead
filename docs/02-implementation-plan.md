# Chatterhead — Implementation Plan

**Status:** ready to implement
**Date:** 2026-08-28
**Input:** [`docs/01-architecture-options.md`](01-architecture-options.md) — read it first; this document does not repeat its rationale.
**Chosen direction:** **Plan B** — Idiomatic Minimal + Presence Client (axes 2b · 3a · 4a · 5a · 6b).

---

## 0. How to use this document

Each task below is a self-contained ticket: it can be implemented, tested, reviewed, and merged
without any later ticket existing. Tasks are ordered so that dependencies always precede dependents.

Every ticket has four parts:

- **Summary** — what the ticket delivers.
- **Commits** — the atomic commit sequence. Each commit is a focused, self-contained unit of work,
  compiles cleanly, and leaves the test suite green. **Unit tests ship in the commit that introduces
  the logic they test**, never in a follow-up "add tests" commit.
- **Notes** — background the implementer needs, plus open questions a developer must decide before
  or during implementation.
- **Acceptance criteria** — observable behaviours that must hold when the ticket is done.

Run `mix precommit` before every commit. It is already aliased in `mix.exs` to
`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`.

---

## 1. Decisions locked in

Settled before implementation begins. Do not relitigate these mid-ticket; if one turns out to be
wrong, that is a plan change, not an implementation detail.

| # | Decision | Source |
|---|---|---|
| D1 | Two contexts: `Chatterhead.Accounts`, `Chatterhead.Chat`. The web layer never touches `Repo` | doc 01 §3.1 |
| D2 | `Phoenix.PubSub` for fan-out; `Phoenix.Presence` for presence. No hand-rolled tracker | doc 01 §4 Axis 1 |
| D3 | **Presence client** (`init/1` + `handle_metas/4`) re-broadcasts semantic events; LiveViews never decode raw presence diffs | doc 01 §5 Plan B |
| D4 | `last_seen_at` persisted from the presence client via a supervised `Task` | doc 01 §5 Plan B |
| D5 | No room process. One global room; Postgres is the source of truth | doc 01 §4 Axis 3 |
| D6 | Identity via a session cookie set by a plain controller (`POST /join`), read by an `on_mount` hook | doc 01 §4 Axis 4a |
| D7 | Two LiveViews — `LobbyLive` at `/`, `RoomLive` at `/room` — in **two** `live_session` blocks (`:current_scope` for `/`, `:joined` for `/room`), because `on_mount` hooks are per-`live_session` and only the room requires a joined user. Doc 01 Axis 5a said one; the guard requirement is what changed it. See CHAT-7 | doc 01 §4 Axis 5a, amended |
| D8 | **Windowed history + keyset "load older"** (Axis 6b), fully built — not deferred | decided 2026-08-28 |
| D9 | Messages use a LiveView **stream**; the roster is a **plain assign** | doc 01 §3.4 |
| D10 | `citext` for names; `:utc_datetime_usec` for message timestamps | doc 01 §7 |
| D11 | **Purpose-built chat layout** — app shell replaces the generated marketing chrome; two-pane room; scroll hook. Built on the shipped `core_components.ex`, not a from-scratch design system | decided 2026-08-28 |
| D12 | Postgres via a committed `docker-compose.yml`; a local install stays supported | decided 2026-08-28 |
| D13 | GitHub Actions CI running the `precommit` checks | decided 2026-08-28 |

---

## 2. Target module map

```
lib/chatterhead/
  application.ex              (+ Presence, + Task.Supervisor children)
  accounts.ex                 join/1, list_users/0, get_user/1, touch_last_seen/2
  accounts/user.ex            schema + changeset
  accounts/scope.ex           %Scope{user: %User{}}
  accounts/roster.ex          pure projection: users x online set -> sorted entries
  accounts/roster/entry.ex    %Entry{id, name, online?, last_seen_at}
  chat.ex                     list_recent/1, list_before/2, send_message/2, topic/0, subscribe/0
  chat/message.ex             schema + changeset

lib/chatterhead_web/
  channels/presence.ex        use Phoenix.Presence + init/1 + handle_metas/4 + track_user/2 + online_users/0
                              NOTE: `mix phx.gen.presence` writes to channels/, not the web root
                              (verified: deps/phoenix/lib/mix/tasks/phx.gen.presence.ex:46).
                              Keep the generated path; do not git mv it.
  user_auth.ex                fetch_current_scope plug, on_mount hooks, log_in_user/2, log_out_user/1
  controllers/session_controller.ex   create/2 (join), delete/2 (leave)
  live/lobby_live.ex          roster + join form
  live/room_live.ex           presence tracking, streamed history, compose form
  components/chat_components.ex       roster, status dot, message, time labels
  components/layouts.ex       app shell (rewritten)

test/support/
  presence_case.ex            eventually/2, drain_presence_fetchers/0        (created in CHAT-4)
  conn_case.ex                extended: import Phoenix.LiveViewTest, log_in/2 (extended in CHAT-7)
```

`ConnCase` as generated is bare — it imports `Plug.Conn` and `Phoenix.ConnTest` and nothing else.
There is no `phx.gen.auth` scaffolding in this repo to lean on, so `import Phoenix.LiveViewTest` and
every session helper is net-new (CHAT-7).

Deleted along the way: `controllers/page_controller.ex`, `controllers/page_html.ex`,
`controllers/page_html/home.html.heex`, `test/chatterhead_web/controllers/page_controller_test.exs`.

Dependency arrows point inward: `chatterhead_web` may call `chatterhead`; never the reverse.
`Chatterhead.Accounts` and `Chatterhead.Chat` do not know `Phoenix.Presence` exists.

---

## 3. Shared contracts

These are the interfaces tickets agree on. Fix them before CHAT-4; changing one later touches
several tickets.

### 3.1 Topics — there are three, and conflating them is a bug

| Constant | Value | Published by | Subscribed by | Payload |
|---|---|---|---|---|
| `Chat.topic/0` | `"chat:room"` | `Chat.send_message/2` | both LiveViews | `{:new_message, %Message{user: %User{}}}` |
| `Presence.topic/0` | `"chat:presence"` | `Phoenix.Tracker` (internal) | **nobody** | raw `%Phoenix.Socket.Broadcast{event: "presence_diff"}` |
| `Presence.events_topic/0` | `"chat:presence:events"` | `Presence.handle_metas/4` | both LiveViews | `{:user_online, ...}` / `{:user_offline, ...}` |

**Why the presence tracking topic is separate from the presence events topic.** `Phoenix.Presence`
broadcasts a raw `presence_diff` to whatever topic you `track/4` on. If LiveViews subscribed to that
same topic, every diff would land in their `handle_info/2` and either crash them or force a no-op
catch-all clause — which is exactly the coupling the presence client exists to remove. Tracking on
its own topic keeps subscribers free of Presence's data shape.

This is a deliberate refinement of doc 01 §3.2 ("one topic for the room"), which was written for the
Plan A / Axis 2a shape where LiveViews *do* consume raw diffs.

> **Trap — `handle_metas/4` must ignore its own `topic` argument.** The `Phoenix.Presence` moduledoc
> example broadcasts with `local_broadcast(MyApp.PubSub, topic, msg)`, reusing the *tracked* topic
> (`deps/phoenix/lib/phoenix/presence.ex:164` and `:178`). Copying that here publishes semantic events
> on `"chat:presence"` alongside the raw diffs, and the entire decoupling in this table collapses.
> **Always broadcast on `events_topic()`.** The `topic` argument is used only as the key into client
> state, never as a broadcast destination.

### 3.2 Presence meta and event payloads

Tracked meta (`Presence.track_user/2`):

```elixir
%{id: user.id, name: user.name, online_at: DateTime.utc_now()}
```

`id` is the **integer** id, carried in the meta on purpose. `Phoenix.Presence` casts the presence
*key* to a string; by reading `id` out of the meta instead of parsing the key, the string/integer
trap from doc 01 §8 is closed at the Presence boundary and never reaches `Roster`.

Carrying `name` in the meta is also what lets us skip the `fetch/2` callback entirely, which keeps
the database out of Presence's fetcher processes and sidesteps the sandbox problem (§6.2).

Semantic events broadcast on `Presence.events_topic/0`:

```elixir
{:user_online,  %{id: 7, name: "alice"}}
{:user_offline, %{id: 7, name: "alice", at: ~U[2026-08-28 12:00:00Z]}}
```

The `at` in `:user_offline` is the same timestamp written to `users.last_seen_at`, so every client's
roster and the database agree without a re-query.

**`at` must be second-precision — truncate once, at the source.** `users.last_seen_at` is a
`:utc_datetime` column (CHAT-2), and `Ecto.Type.dump(:utc_datetime, ...)` routes through
`check_no_usec!/2`, which **raises `ArgumentError`** on any non-zero microsecond value
(`deps/ecto/lib/ecto/type.ex:582`, `:613`, `:1587-1595`). `DateTime.utc_now/0` returns `{n, 6}`
precision, so passing it straight to `Repo.update_all` crashes the first time anyone goes offline —
it does not silently truncate. Compute
`at = DateTime.utc_now() |> DateTime.truncate(:second)` once in `handle_metas/4` and use that single
value for both the broadcast and the write. (Truncating is preferred over widening the column to
`:utc_datetime_usec`: it keeps `last_seen_at` consistent with the second-precision `users.inserted_at`
beside it, for a field the UI renders as "2m ago".)

### 3.3 Online-set and roster shapes

```elixir
# ChatterheadWeb.Presence.online_users/0
%{7 => %{id: 7, name: "alice"}, 9 => %{id: 9, name: "bob"}}   # keyed by integer id

# Chatterhead.Accounts.Roster.Entry
%Entry{id: 7, name: "alice", online?: true, last_seen_at: nil}
```

---

## 4. Task board

```
CHAT-1  Dev environment and CI
   |
   +-- CHAT-2  Accounts context ----+-- CHAT-3  Chat context ------------+
   |                                |                                   |
   |                                +-- CHAT-4  Presence + client --+    |
   |                                                                |    |
   |                                        CHAT-5  Roster <--------+    |
   |                                             |                       |
   +-- CHAT-6  App shell + components -----------+                       |
                                                 |                       |
                                        CHAT-7  Join flow                |
                                                 |                       |
                          +----------------------+-----------------------+
                          |                                        |
                   CHAT-8  Lobby roster                    CHAT-9  Room messages
                          |                                        |
                          |                                CHAT-10 Load older
                          |                                        |
                          +------------- CHAT-11 Room roster ------+
                                                 |
                                        CHAT-12 Multi-client tests
                                                 |
                                        CHAT-13 README
```

Only CHAT-2 and CHAT-6 are genuinely parallelisable after CHAT-1. Everything else in the early group
has a real dependency, exactly as the arrows show: **CHAT-3 needs CHAT-2** (the `messages` migration
carries `references(:users)` and `Message` has `belongs_to :user`), **CHAT-4 needs CHAT-2** (for
`Accounts.touch_last_seen/2`), and **CHAT-5 needs the event shapes fixed in §3** plus CHAT-2's `User`
struct.

---

# CHAT-1 — Development environment and CI

## Summary

Make the repo runnable and verifiable on a machine that is not the author's. Ship a Docker Compose
file for Postgres with credentials that match the committed config, and a CI workflow that runs the
same checks `mix precommit` runs. Landing this first means every subsequent ticket is gated.

## Commits

**1. `chore: add docker compose for local postgres`**

- `docker-compose.yml` at the repo root:
  - image `postgres:17-alpine`, pinned by major version
  - `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=postgres` — **must** match `config/dev.exs:4-11` and
    `config/test.exs:8-14`, which the scaffold already set to `postgres`/`postgres`/`localhost`
  - port mapping `5432:5432`
  - named volume for `/var/lib/postgresql/data`
  - a `healthcheck` using `pg_isready` so `docker compose up -d --wait` blocks until the DB accepts
    connections
- No test. Verified by the acceptance criteria below.

**2. `ci: verify compile, format, and tests on push and pull request`**

- `.github/workflows/ci.yml`:
  - triggers: `push` to `main`, and `pull_request`
  - `services.db` — `postgres:17-alpine` with the same credentials and a health check
  - `erlef/setup-beam` pinned to Elixir 1.20 / OTP 29 (the versions this repo is developed on)
  - cache `deps/` and `_build/` keyed on `mix.lock` and the OTP/Elixir versions
  - steps, in order: `mix deps.get` → `mix deps.unlock --check-unused` →
    `mix compile --warnings-as-errors` → `mix format --check-formatted` → `mix test`
- No test.

## Notes

**Background.** `mix test` is already aliased to run `ecto.create --quiet` and `ecto.migrate --quiet`
first ([mix.exs:86](../mix.exs#L86)), so CI needs no explicit database setup step beyond a reachable
server. Doc 01 §2 records that Postgres.app was installed but not accepting connections when the
scaffold was surveyed — the compose file removes that as a source of "works on my machine".

**`format` vs `format --check-formatted`.** The `precommit` alias runs `mix format`, which *rewrites*
files. That is correct locally and wrong in CI, where a rewrite would silently pass. CI must run
`--check-formatted` so unformatted code fails the build. Do not "fix" this by changing the alias —
the two behaviours are both wanted, in different places.

**`citext` needs elevated privileges.** CHAT-2's migration runs `CREATE EXTENSION IF NOT EXISTS
citext`. The Postgres service container's default `postgres` role is a superuser, so CI is fine. A
managed Postgres that withholds extension-create privileges would need the `lower(name)` functional
index fallback from doc 01 §7 — note this in the README, do not build it.

**Port 5432 will collide with a running Postgres.app.** Doc 01 §2 records that Postgres.app is
installed on the development machine; if it is running, `docker compose up` fails with "port is
already allocated". Either stop the local server (`pg_ctl stop`, or quit Postgres.app) or remap the
host side (`"5433:5432"`) and set `PGPORT`/the `:port` key in `config/dev.exs` and `config/test.exs`
to match. Say which in the README — a reviewer with Postgres already running will hit this first.

**Verify the toolchain versions actually publish before pinning them.** `mix.exs` only declares
`elixir: "~> 1.17"`; the development machine runs Elixir 1.20.4 on OTP 29 (erts-17.0.5). Confirm
`erlef/setup-beam` ships builds for the exact pair you pin rather than assuming it — a version that
does not resolve fails the workflow at setup, before any useful signal.

**Open questions**

1. Pin a single Elixir/OTP pair, or run a small matrix (e.g. 1.17 and 1.20) to honour the
   `elixir: "~> 1.17"` requirement in `mix.exs`? A matrix is more honest about the declared support
   range; a single pin is faster and is what the author actually ran.
2. Commit a `.tool-versions` (asdf/mise) so contributors and CI read the same versions from one
   place? The repo has none today.
3. Postgres major version — 17 (current) or 16 (more conservative)? Whichever is chosen must be
   identical in `docker-compose.yml` and the CI service container.

## Acceptance criteria

- [ ] On a clean checkout with Docker running and no local Postgres bound to 5432,
      `docker compose up -d --wait && mix setup` succeeds with no edits to any config file.
- [ ] The README tells a reader with a local Postgres already on 5432 exactly what to do.
- [ ] `mix test` passes against the containerised database.
- [ ] A pull request runs the workflow and reports a green check.
- [ ] Introducing a deliberately unformatted file makes CI fail on the format step, not the test step.
- [ ] Introducing a deliberate compiler warning makes CI fail on the compile step.

---

# CHAT-2 — Accounts context: users and joining

## Summary

The `Chatterhead.Accounts` context: a `User` schema with case-insensitively unique names, a
race-safe find-or-create `join/1`, the query that backs the "list of all users" requirement (A1),
the `Scope` struct that carries identity through the web layer, and seed data so a fresh database is
not an empty screen.

## Commits

**1. `feat: add users table with case-insensitive unique names`**

- `mix ecto.gen.migration create_users` (per AGENTS.md, always use the generator for the timestamp)
- Up/down-safe extension creation:
  ```elixir
  execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"
  ```
- Table:
  ```elixir
  create table(:users) do
    add :name, :citext, null: false
    add :last_seen_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  create unique_index(:users, [:name])
  ```
- `last_seen_at` is deliberately `:utc_datetime` (second precision), unlike `messages.inserted_at`.
  Every writer must therefore hand it a truncated `DateTime` — see §3.2; Ecto **raises** rather than
  truncating for you.
- No test — migrations are exercised by every subsequent test run.

**2. `feat: add User schema with name changeset`**

- `Chatterhead.Accounts.User`: `field :name, :string` (per AGENTS.md, Ecto uses `:string` even for
  `citext`/`:text` columns), `field :last_seen_at, :utc_datetime`, `has_many :messages`,
  `timestamps(type: :utc_datetime)`
- `changeset/2`:
  - `cast([:name])` — `last_seen_at` is set programmatically and must **not** be castable
  - normalise before validating: trim, and collapse internal whitespace runs to a single space
  - `validate_required(:name)`
  - `validate_length(:name, min: 1, max: 32)`
  - `validate_format(:name, ~r/^[^\p{C}]+$/u)` — reject control characters
  - `unique_constraint(:name)`
- Tests (`test/chatterhead/accounts/user_test.exs`, `async: true`): trimming, whitespace collapsing,
  blank rejection, length bounds at the boundary, control-character rejection.

**3. `feat: add Accounts.join/1 and list_users/0`**

- `join(name)` — find-or-create, tolerant of the concurrent-insert race (doc 01 §8):
  1. build and validate the changeset; return `{:error, changeset}` on invalid input
  2. look up by normalised name (`citext` makes the comparison case-insensitive)
  3. if absent, `Repo.insert(changeset, on_conflict: :nothing, conflict_target: :name)`
  4. if the returned struct has a `nil` id, another process won the race — re-fetch and return theirs
- `list_users/0` — all users ordered by name ascending
- `get_user/1` and `get_user!/1`
- `change_user/2` — exposes the changeset for LiveView forms without leaking the schema module
- Tests, in **two files**, because `async` is an ExUnit *module-level* setting that cannot be
  overridden per test:
  - `test/chatterhead/accounts_test.exs` (`async: true`) — creates on first call; returns the *same*
    user on a second call; `"Jason"` and `"jason"` resolve to one user; invalid names return
    `{:error, changeset}` with no insert; `list_users/0` ordering.
  - `test/chatterhead/accounts_join_race_test.exs` (**`async: false`**) — the concurrency test alone:
    two `Task.async` calls to `join/1` with the same brand-new name return the same id and leave
    exactly one row. It must be `async: false` because the spawned tasks do not own a sandbox
    connection and need the Repo in shared mode. Putting it in the `async: true` file is not merely
    ineffective — forcing shared mode from an async module breaks isolation for every other module
    running concurrently.

**4. `feat: add Accounts.Scope for current-user assigns`**

- `Chatterhead.Accounts.Scope`: `defstruct [:user]`, `for_user(%User{})` → `%Scope{}`,
  `for_user(nil)` → `nil`
- Test: both clauses.

**5. `feat: seed demo users`**

- `priv/repo/seeds.exs` inserts four or five users through `Accounts.join/1`
- Idempotent by construction — `join/1` is find-or-create, so re-running `mix run priv/repo/seeds.exs`
  or `mix ecto.reset` is safe
- No test.

## Notes

**Background.** Requirement A1 is "a list of **all** users", including users who have never been
online this boot — so the roster's source of truth is the `users` table, not Presence. Seeds exist so
that A1 and the offline state are both demonstrable in a single browser window without staging a
second visitor.

**Why `citext` and not a changeset-level check.** A `validate_*` uniqueness check loses every race.
The unique index is the actual guarantee; `unique_constraint/2` only translates the resulting
database error into a changeset error. `citext` moves case-insensitivity into the comparison
semantics of the column, so both the lookup in `join/1` and the index get it for free — no
`lower(name)` in queries, nothing to forget at a call site.

**`last_seen_at` lands here but is written in CHAT-4.** One migration for the final `users` shape is
worth more than a second migration three tickets later. The column is nullable and unused until
CHAT-4; nothing is broken in between. A `nil` value means "never seen online", which the roster
renders differently from a real timestamp.

**Normalisation belongs in the changeset**, not in `join/1`, so that every write path gets it.

**Open questions**

1. **Maximum name length** — 32 is a guess that renders comfortably in a sidebar. Anything from 20 to
   50 is defensible; pick one and use it in the changeset, the input's `maxlength`, and the tests.
2. **Should `join/1` refresh `last_seen_at`?** Rejoining is a presence event, and CHAT-4 already
   writes on leave. Writing on join too would make "last seen" mean "last activity" rather than "last
   went offline". Decide and document; the roster copy depends on it.
3. **Should the seeds also insert messages?** CHAT-10's "load older" control is only visible when
   history exceeds one page, so seeding ~60 messages makes keyset pagination demonstrable in a fresh
   database without typing. Counter-argument: seeded chatter is noise on first impression. If yes,
   this becomes a commit in CHAT-3 (it needs the `Message` schema), not here.
4. Are any names reserved (`system`, `admin`)? Currently no — and doc 01 §10 records that a name is
   an unverified identity claim by design.

## Acceptance criteria

- [ ] `Accounts.join("alice")` creates a user; a second call with `"ALICE"` returns the same struct
      and leaves exactly one row in `users`.
- [ ] `Accounts.join("  alice   smith ")` stores `"alice smith"`.
- [ ] `Accounts.join("")` and `Accounts.join("   ")` both return `{:error, %Ecto.Changeset{}}` and
      insert nothing.
- [ ] Two concurrent `join/1` calls with the same new name both succeed and return the same id.
- [ ] `Accounts.list_users/0` returns every persisted user, name-ascending.
- [ ] A direct `Repo.insert` of a duplicate name is rejected by the database, not just by the changeset.
- [ ] `mix ecto.reset` runs the seeds without error, twice in a row.

---

# CHAT-3 — Chat context: messages, history, and fan-out

## Summary

The `Chatterhead.Chat` context: a `Message` schema, the windowed history query and its keyset
continuation (D8), and `send_message/2`, which persists and then broadcasts on the room topic. This
ticket contains every requirement-bearing behaviour of A5 and A7 except the rendering.

## Commits

**1. `feat: add messages table with keyset pagination index`**

- `mix ecto.gen.migration create_messages`
  ```elixir
  create table(:messages) do
    add :body, :text, null: false
    add :user_id, references(:users, on_delete: :delete_all), null: false
    timestamps(type: :utc_datetime_usec)
  end

  create index(:messages, [:user_id])
  create index(:messages, [:inserted_at, :id])
  ```
- No test.

**2. `feat: add Message schema with body validation`**

- `Chatterhead.Chat.Message`: `field :body, :string`, `belongs_to :user`,
  `timestamps(type: :utc_datetime_usec)` — the precision must be declared in **both** the migration
  and the schema or it will not round-trip
- `changeset/2` casts **only** `[:body]`; `user_id` is set on the struct by the caller, never cast
  (AGENTS.md, Ecto guidelines)
- Trim the body, `validate_required(:body)`, `validate_length(:body, max: 2000)`,
  `assoc_constraint(:user)`
- Tests (`async: true`): whitespace-only body rejected; trimming; length boundary; `user_id` is not
  castable (passing it in attrs must not change the struct).

**3. `feat: add Chat.list_recent/1 and keyset pagination`**

- `@page_size 50`
- `list_recent(limit \\ @page_size)` → `{messages, more?}`
  - query newest-first, `limit: limit + 1`, `preload: :user`
  - if `limit + 1` rows came back, `more? == true`; drop the extra row
  - **return the page oldest-first**
- `list_before({inserted_at, id}, limit \\ @page_size)` → `{messages, more?}`
  - keyset predicate using Postgres row-value comparison. **The pinned datetime must be type-hinted**
    — inside a `fragment/1` Ecto has no field to infer from, so Postgrex encodes a bare `%DateTime{}`
    as `timestamptz` while `m.inserted_at` is `timestamp` (no zone). The comparison then leans on an
    implicit cast that happens to work only while the database session is UTC:
    ```elixir
    where:
      fragment(
        "(?, ?) < (?, ?)",
        m.inserted_at,
        m.id,
        type(^inserted_at, m.inserted_at),
        ^id
      )
    ```
    The fully-typed alternative avoids the fragment entirely —
    `where: m.inserted_at < ^ts or (m.inserted_at == ^ts and m.id < ^id)` — but the row-value form is
    the crisper index range scan, so prefer it with the `type/2` hint.
  - newest-first, `limit: limit + 1`, `preload: :user`, same `more?` trick
  - **also returns oldest-first** — both functions return the same orientation so call sites cannot
    confuse them. CHAT-10 reverses before prepending; that reversal is documented there.
- `cursor(message)` → `{message.inserted_at, message.id}`
- Tests (`async: true`): oldest-first ordering; two messages inserted with an *identical*
  `inserted_at` are ordered by `id` (the tie case doc 01 §7 calls out); `more?` is `true` at exactly
  `page_size + 1` rows and `false` at exactly `page_size`; `list_before/2` excludes the cursor row
  itself; pages tile the history with no gap and no overlap; `user` is preloaded on every returned
  message.

**4. `feat: add Chat.send_message/2 with PubSub broadcast`**

- `@topic "chat:room"`, `topic/0`, `subscribe/0` (`Phoenix.PubSub.subscribe(Chatterhead.PubSub, @topic)`)
- `send_message(%Scope{user: user}, attrs)`:
  ```elixir
  %Message{user_id: user.id}
  |> Message.changeset(attrs)
  |> Repo.insert()
  |> case do
    {:ok, message} ->
      message = %{message | user: user}
      Phoenix.PubSub.broadcast(Chatterhead.PubSub, @topic, {:new_message, message})
      {:ok, message}

    {:error, changeset} ->
      {:error, changeset}
  end
  ```
- `change_message/2` for the compose form
- Tests (`async: true`): a subscriber receives `{:new_message, %Message{}}`; the broadcast payload has
  `user` loaded (not `%Ecto.Association.NotLoaded{}`); an invalid body inserts nothing **and**
  broadcasts nothing (`refute_receive`).

## Notes

**Why `:utc_datetime_usec`.** The generator default `:utc_datetime` truncates to whole seconds. Two
messages sent in the same second would tie, and a chat log that reorders on reload is precisely the
bug this exercise is looking for. Sorting by `[inserted_at, id]` keeps ordering deterministic even so.

**Why keyset and not offset.** `OFFSET 50` is defined relative to a result set that shifts every time
a new row is inserted — under a live chat that means duplicated or skipped messages when paging back.
The `(inserted_at, id) < (?, ?)` predicate is anchored to a row, not a position, so concurrent
inserts cannot disturb it. The `[:inserted_at, :id]` index makes it an index range scan.

**Row-value comparison is Postgres syntax**, expressed through `fragment/1` because Ecto has no
native tuple-comparison operator. It is correct and portable across every database this app targets
(exactly one). Note it in the README rather than hiding it.

**Why broadcast from the context, not the LiveView.** If the LiveView broadcasts, an IEx session or a
future HTTP API that calls `send_message/2` silently notifies nobody. Broadcasting after a successful
insert makes "persisted" and "fanned out" one operation with one failure mode.

**Why the broadcast carries a fully-loaded struct.** Sending a bare `%Message{}` with an unloaded
association forces every connected client to issue its own query on every message — an N+1 that
scales with connections rather than data. We already hold the sender's `%User{}` in the scope, so
`%{message | user: user}` avoids even a single query.

**No local echo.** The sender receives their own message through PubSub like everyone else. One code
path, guaranteed identical ordering everywhere, no duplicate-render bug. The cost is a round trip to
a local process.

**Open questions**

1. **Page size** — 50 is a conventional default. It interacts with CHAT-2 open question 3 (how many
   messages to seed) and with whether "load older" is visible in a demo.
2. **Maximum body length** — 2000 characters. Should the limit be surfaced in the UI (a counter, a
   `maxlength` attribute) or only enforced server-side?
3. **Does `send_message/2` take a `%Scope{}` or a `%User{}`?** Scope is consistent with D6 and with
   Phoenix 1.8 conventions; a bare `%User{}` is a smaller contract. Pick one and use it everywhere.
4. Should `Chat` expose a `count_messages/0` for an "N messages" affordance? Streams cannot be counted
   (AGENTS.md), so any count needs a separate assign. Only worth it if the UI shows one.

## Acceptance criteria

- [ ] A message is persisted with a microsecond-precision `inserted_at`.
- [ ] Two messages written inside the same second load back in insertion order.
- [ ] `list_recent/1` returns at most `page_size` messages, oldest-first, each with `user` preloaded.
- [ ] `more?` is `true` when unshown history exists and `false` when the returned page is the whole history.
- [ ] `list_before/2` returns the page immediately preceding the cursor with no overlap and no gap.
- [ ] Inserting new messages between two `list_before/2` calls does not duplicate or skip any message.
- [ ] A process subscribed via `Chat.subscribe/0` receives `{:new_message, message}` after a successful send.
- [ ] A rejected message produces no row and no broadcast.

---

# CHAT-4 — Presence tracking and the presence client

## Summary

Presence infrastructure, and the piece that makes this Plan B rather than Plan A: a
`Phoenix.Presence` module that also acts as an **Elixir presence client**, holding the online set as
process state, translating raw tracker diffs into semantic `{:user_online, ...}` /
`{:user_offline, ...}` events, and persisting `last_seen_at` through a supervised task.

No LiveView work here — this ticket is testable entirely with bare processes.

## Commits

**1. `test: add presence-aware test helpers`**

- `test/support/presence_case.ex`:
  - `eventually(fun, timeout \\ 500)` — retries an assertion on an interval until it passes or the
    timeout expires, then asserts once more so the failure message is the real one. Required because
    `Phoenix.Tracker` is eventually consistent; a bare assertion immediately after tracking passes
    locally and flakes in CI.
  - `drain_presence_fetchers/0` — for `on_exit`, monitoring and awaiting every pid from
    `ChatterheadWeb.Presence.fetchers_pids/0` (the pattern from the `Phoenix.Presence` moduledoc;
    `fetchers_pids/0` is present in the vendored 1.8.13 source at `presence.ex:423`)
- `test/support` is already compiled in `:test` ([mix.exs:35](../mix.exs#L35)), so no `mix.exs` change
  is needed.
- These helpers live here, not in a later ticket, because **this ticket's own tests are their first
  consumer** — §0 promises every ticket is implementable without any later ticket existing.
- `eventually/2` polls on a timer, which brushes against AGENTS.md's "avoid `Process.sleep/1` in
  tests". That rule is about waiting on a *named process* whose completion you can monitor
  (`Process.monitor/1` + `assert_receive {:DOWN, ...}`). CRDT convergence has no such process and no
  completion message, so bounded polling is the only correct tool. Say so in the module doc.
- No test of its own; exercised by the next commit.

**2. `feat: add Presence tracking supervised in the application tree`**

- `mix phx.gen.presence` → generates `ChatterheadWeb.Presence` at
  **`lib/chatterhead_web/channels/presence.ex`** (the generator's fixed path, `phx.gen.presence.ex:46`)
  with `use Phoenix.Presence, otp_app: :chatterhead, pubsub_server: Chatterhead.PubSub`
- Supervision tree in [application.ex](../lib/chatterhead/application.ex#L10), in this order:
  `{Phoenix.PubSub, ...}` → `{Task.Supervisor, name: Chatterhead.TaskSupervisor}` (added in commit 4)
  → `ChatterheadWeb.Presence` → `ChatterheadWeb.Endpoint`. Presence depends on the PubSub server, and
  `handle_metas/4` will call into `Chatterhead.TaskSupervisor`, so both must already be started.
- **`ChatterheadWeb.Presence` already starts its own `Task.Supervisor`** — `use Phoenix.Presence`
  registers `ChatterheadWeb.Presence.TaskSupervisor` inside the Presence subtree
  (`presence.ex:371`, `:462`) for the `fetch/2` fetcher processes. Do **not** reuse it for
  application work; `Chatterhead.TaskSupervisor` is a separate, deliberately-owned supervisor.
- Public API on the module:
  - `topic/0` → `"chat:presence"`
  - `track_user(pid, %User{} = user)` → `track(pid, topic(), to_string(user.id), %{id: user.id, name: user.name, online_at: DateTime.utc_now()})`
  - `online_users/0` → walks `list(topic())` metas into `%{integer_id => %{id: , name: }}` (§3.3)
- Tests (`test/chatterhead_web/presence_test.exs`, **`async: false`**): a spawned, tracked process
  appears in `online_users/0`; killing it removes the entry; two processes tracked under the same
  user id yield **one** entry.

**3. `feat: broadcast semantic presence events from a presence client`**

- `events_topic/0` → `"chat:presence:events"`
- Implement the optional callbacks on `ChatterheadWeb.Presence`. **Do not adapt the moduledoc example
  — it does not apply here.** Write this:

  ```elixir
  # Argument shapes, verified against deps/phoenix/lib/phoenix/presence.ex:
  #
  #   joins / leaves : %{key :: String.t() => %{metas: [meta, ...]}}
  #                    built by group/1 (:573) then passed through fetch/2 (:625).
  #                    fetch/2 is NOT implemented here, so it is the identity (:376) and
  #                    there is NO :user key. The moduledoc's `presence.user` raises KeyError.
  #
  #   presences      : %{key :: String.t() => [meta, ...]}
  #                    A DIFFERENT SHAPE - a bare meta list, not %{metas: [...]}  (:680-698).
  #                    A key is deleted outright once its last meta leaves (:711-716).
  #
  #   meta           : %{id: integer, name: String.t(), online_at: DateTime.t()}  (see §3.2)
  #
  #   state          : %{topic => %{key => %{id: integer, name: String.t()}}}

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_metas(topic, %{joins: joins, leaves: leaves}, presences, state) do
    at = DateTime.truncate(DateTime.utc_now(), :second)
    known = Map.get(state, topic, %{})

    known =
      Enum.reduce(joins, known, fn {key, %{metas: [meta | _]}}, acc ->
        if Map.has_key?(acc, key) do
          # A second tab for someone already online. Not a transition; stay quiet.
          acc
        else
          user = %{id: meta.id, name: meta.name}
          publish({:user_online, user})
          Map.put(acc, key, user)
        end
      end)

    known =
      Enum.reduce(leaves, known, fn {key, _presence}, acc ->
        # `presences` is post-diff: a key still present means other tabs remain open.
        if Map.has_key?(presences, key) do
          acc
        else
          case Map.fetch(acc, key) do
            {:ok, user} ->
              publish({:user_offline, Map.put(user, :at, at)})
              Map.delete(acc, key)

            :error ->
              acc
          end
        end
      end)

    {:ok, Map.put(state, topic, known)}
  end

  # NOTE: events go to events_topic(), never to the `topic` argument. See §3.1.
  defp publish(message) do
    Phoenix.PubSub.local_broadcast(Chatterhead.PubSub, events_topic(), message)
  end
  ```

- **`init/1` is mandatory.** `Phoenix.Presence` raises `ArgumentError` at startup if `handle_metas/4`
  is defined without it (`presence.ex:489`).
- **The `topic` argument is a state key, not a broadcast destination.** See the §3.1 trap box — this
  is the single easiest way to silently undo the whole design.
- **`Map.has_key?(presences, key)` is the leave test**, not a count and not a length check. It works
  because Presence deletes a key entirely once its last meta is gone (`presence.ex:711-716`).
  `Map.get(presences, key, []) == []` is equivalent but states the invariant less directly.
- `local_broadcast/3`, not `broadcast/3` — see Notes.
- Tests (**`async: false`**): subscribe to `events_topic/0`, then —
  - tracking a process emits exactly one `{:user_online, %{id: id}}`
  - tracking a *second* process for the same user emits no further `:user_online`
    (`refute_receive`)
  - killing one of the two emits no `:user_offline`
  - killing the second emits exactly one `{:user_offline, %{id: id, at: %DateTime{}}}`
  - `on_exit` drains `Presence.fetchers_pids/0` (§6.2)

**4. `feat: persist last_seen_at when a user goes offline`**

- `Accounts.touch_last_seen(user_id, at)` — a single targeted `Repo.update_all` on the user row, no
  changeset, no read. Idempotent and safe from any process. **`at` must already be second-truncated**;
  `update_all` dumps through `:utc_datetime`, which raises on microseconds (§3.2).
- Add `{Task.Supervisor, name: Chatterhead.TaskSupervisor}` to the application supervision tree,
  positioned before `ChatterheadWeb.Presence` (commit 2).
- Extend the leave branch of `handle_metas/4` so a slow database cannot block the tracker — two lines
  inserted next to the existing `publish/1` call:
  ```elixir
  {:ok, user} ->
    publish({:user_offline, Map.put(user, :at, at)})

    Task.Supervisor.start_child(Chatterhead.TaskSupervisor, fn ->
      Accounts.touch_last_seen(user.id, at)
    end)

    Map.delete(acc, key)
  ```
  The `at` handed to the task is the **same already-truncated value** carried in the
  `{:user_offline, ...}` broadcast, so every client's roster and the database agree with no re-query.
- Tests: `touch_last_seen/2` unit test in the Accounts test file (`async: true`); an integration test
  in the presence test file (**`async: false`**) that kills the last tracked process for a user and
  asserts `last_seen_at` becomes non-nil, using the `eventually/2` helper from commit 1 because the
  write is asynchronous. Assert the persisted value equals the broadcast `at` exactly — that is the
  precision contract, and it fails loudly if anyone reintroduces an untruncated timestamp.

## Notes

**Background — why this shape is the OTP answer.** The tempting move on an "OTP concepts" exercise is
a `GenServer` holding `%{user_id => pid}` with `Process.monitor/1` and `:DOWN` cleanup. It works on
one node and it is the wrong answer, for reasons worth stating in the README: `Phoenix.Presence` is
built on `Phoenix.Tracker`, a CRDT-based, eventually-consistent, distributed tracker that already
does the monitor-and-clean-up, survives netsplits, and is not a single serialization point. Reaching
for a well-designed OTP library is the senior move; reimplementing it badly is the junior one. The
presence *client* is genuine process work — state, callbacks, supervised side effects — done at an
extension point the library explicitly documents, rather than in place of the library.

**Honest caveat for the README:** those resilience properties are about multi-node behaviour. On a
single node, if the tracker process crashes, local presence state is lost and live LiveViews are not
re-tracked. Accepted for this exercise (doc 01 §10) — do not oversell it.

**Multi-tab is the correctness centre of this ticket.** "Online" means *the presence key exists*, not
that the meta list has length one. Every join/leave decision must be a transition check against the
post-diff `presences` map or the client state, never a count.

**`local_broadcast/3`, not `broadcast/3`.** `handle_metas/4` runs on every node that has a Presence
process, each already receiving the replicated tracker diff. Using `broadcast/3` would fan the same
semantic event to every node from every node — N² duplicates on a cluster. `local_broadcast/3`
delivers to this node's subscribers only, which is exactly right.

**`client_state` is per tracker shard, not a global registry.** `Phoenix.Tracker` runs `:pool_size`
shards, each with its own Presence state including `client_state`
(`deps/phoenix_pubsub/lib/phoenix/tracker.ex:312`, `:321`). The default is **1**, and topics are
sharded by name, so with a single presence topic every diff lands in one shard and the per-key dedup
above is exact. Raising `:pool_size` would still be safe — a key's diffs always route to the same
shard — but the state is not a cluster-wide or even node-wide registry, and nothing should be written
that assumes it is.

**Nothing here reads the database except `touch_last_seen/2`**, and that runs in a supervised task
rather than in the Presence process. The `fetch/2` callback is deliberately **not** implemented — the
meta already carries `id` and `name` (§3.2). This is what keeps Presence's fetcher processes out of
the Ecto sandbox's way (§6.2).

**Open questions**

1. **Should `last_seen_at` also be written on join?** See CHAT-2 open question 2 — same decision, and
   it changes what the roster label means.
2. **What does "online" mean?** As specified: *present in the room*. A joined user who navigates back
   to the lobby stops being tracked and shows as offline. The alternative is tracking from a shared
   `on_mount` hook so any joined user anywhere in the app counts as online. The first is simpler and
   matches "enters a shared chat room"; the second may match a reviewer's intuition better. Decide
   and document in the README either way.
3. **How should a user with `last_seen_at == nil` be labelled?** "Offline", "Never joined", or a
   dash. Affects CHAT-6's component copy.
4. Is a `Presence.online_count/0` worth exposing separately, or should the roster derive counts?
   (CHAT-5 derives them; this would be a second source of truth.)

## Acceptance criteria

- [ ] `ChatterheadWeb.Presence` starts with the application and appears in the supervision tree.
- [ ] Tracking a process publishes exactly one `{:user_online, %{id: id, name: name}}` on the events topic.
- [ ] Tracking a second process for the same user publishes no additional `:user_online`.
- [ ] Killing one of two processes for the same user publishes no `:user_offline`.
- [ ] Killing the last process for a user publishes exactly one `{:user_offline, %{id:, name:, at:}}`.
- [ ] After that leave, the user's `last_seen_at` is persisted and equals the `at` in the broadcast.
- [ ] Subscribers to `Presence.events_topic/0` never receive a raw `%Phoenix.Socket.Broadcast{event: "presence_diff"}`.
- [ ] No presence code path queries the database from inside the Presence process.

---

# CHAT-5 — Roster projection

## Summary

A pure module that answers "who exists, and which of them are online" by combining the persisted user
list with the presence-derived online set — with no socket, no database, and no knowledge that
`Phoenix.Presence` exists. This is the single place the online/offline rule lives, and it is
exhaustively testable in microseconds.

## Commits

**1. `feat: add Roster projection for online and offline users`**

- `Chatterhead.Accounts.Roster.Entry` — `%Entry{id, name, online?, last_seen_at}`
- `Chatterhead.Accounts.Roster` — an opaque struct wrapping `%{id => Entry}`:
  - `build(users, online_map)` — `users` is `[%User{}]` from `Accounts.list_users/0`, `online_map` is
    the §3.3 shape from `Presence.online_users/0`. Every user becomes an entry; entries whose id is in
    `online_map` get `online?: true`.
  - `mark_online(roster, %{id: , name: })` — sets `online?: true`; **inserts the entry if unknown**,
    which is how a user created after this client mounted appears without a database round trip.
  - `mark_offline(roster, %{id: , name: , at: })` — sets `online?: false` and `last_seen_at: at`.
  - `entries(roster)` — display order: online first, then name ascending, case-insensitively.
  - `counts(roster)` — `%{online: n, offline: n}`, derived, never stored.
- Tests (`test/chatterhead/accounts/roster_test.exs`, `async: true`) covering every clause:
  - `build/2` with an empty online map marks everyone offline
  - `build/2` marks exactly the users present in the online map
  - an online id with no matching user is still represented (a user created since the list was loaded)
  - `mark_online/2` for an unknown id adds an entry
  - `mark_online/2` is idempotent
  - `mark_offline/2` sets `last_seen_at` from `at`
  - `mark_offline/2` for an unknown id is a no-op rather than a crash
  - `entries/1` puts online before offline, then sorts `"alice"`, `"Bob"`, `"carol"` in that order
  - `counts/1` matches `entries/1`

## Notes

**Background.** Doc 01 §8 frames this as "roster = database LEFT JOIN presence", and keeping it a pure
function is what makes it testable without a socket, a tracker, or a database. Every online/offline
rule the UI depends on is decided here.

**All ids are integers by the time they reach this module.** `Phoenix.Presence` casts its keys to
strings, which is a classic source of silent membership-check failures. §3.2 closes that at the
Presence boundary by carrying the integer `id` in the meta; `Roster` therefore never sees a string id
and its tests should not pretend otherwise.

**Why a struct rather than a bare map.** The incremental `mark_online/2` and `mark_offline/2`
operations are the whole point — a LiveView applies a stream of small events without re-querying —
and a named struct makes the internal shape private so the display ordering can change without
touching call sites.

**Why the roster is not a LiveView stream.** Streams are not enumerable, so partitioning by online
status and re-sorting on every change would mean re-streaming the whole collection with `reset: true`
on every join and leave. The roster is bounded by user count and belongs in a plain assign (D9).

**Open questions**

1. **Sort order within the offline group** — alphabetical (predictable, easy to scan) or most-recently
   seen first (more informative once there are many users)? Alphabetical is specified above.
2. **Should the offline list be capped or collapsed** behind a "show all" toggle once it is long? Out
   of scope as written; worth a README note as a scale consideration.
3. **Where does "(you)" come from?** The current user's own entry needs marking in the UI. Either the
   component takes a `current_user_id` attribute (keeps `Roster` context-free — preferred) or `Entry`
   carries a `you?` flag (denormalises identity into the projection).

## Acceptance criteria

- [ ] Given three persisted users and an online map containing one of them, `entries/1` returns three
      entries with exactly one `online?: true`.
- [ ] `entries/1` lists all online users before any offline user, each group sorted case-insensitively by name.
- [ ] `mark_online/2` with an id absent from the roster adds a visible entry.
- [ ] `mark_offline/2` records the supplied timestamp as `last_seen_at`.
- [ ] `counts/1` always equals the partition sizes of `entries/1`.
- [ ] The module has no reference to `Repo`, `Presence`, or `Phoenix.LiveView`.
- [ ] The whole test file runs `async: true`.

---

# CHAT-6 — Application shell and shared chat components

## Summary

Replace the generated Phoenix marketing chrome with an application shell, and build the small set of
function components both LiveViews render: status dot, roster, message, and time labels. Landing
these before the LiveViews means CHAT-7 through CHAT-11 assemble screens rather than invent markup.

## Commits

**1. `refactor: replace the generated layout chrome with an app shell`**

- Rewrite `Layouts.app` in [layouts.ex](../lib/chatterhead_web/components/layouts.ex#L36):
  - header: product name linking to `/`, the current user's name and a "Leave" link when
    `@current_scope` is present, and the existing `<.theme_toggle />`
  - remove the Phoenix logo, version badge, and the Website/GitHub/Get Started links
  - replace `<main class="px-4 py-20 ..."><div class="mx-auto max-w-2xl ...">` with a full-height
    flex container suitable for a two-pane layout
  - keep `<.flash_group flash={@flash} />` where it is — AGENTS.md forbids calling it anywhere else
- **The existing page test is not affected by this commit.** `home.html.heex` opens with
  `<Layouts.flash_group flash={@flash} />`, not `<Layouts.app>`, so rewriting `Layouts.app` cannot
  break `page_controller_test.exs` (which asserts on the generated marketing copy). The page and its
  test are deleted in CHAT-7, not here — despite the "replace the marketing chrome" framing, this
  commit only touches the layout module.
- The `current_scope` attr is already declared with `default: nil`
  ([layouts.ex:30](../lib/chatterhead_web/components/layouts.ex#L30)), so this commit can read it
  before CHAT-7 assigns it.
- The "Leave" link is `<.link href={~p"/leave"} method="delete">`, which needs the `phoenix_html`
  JS already imported in `assets/js/app.js`. **The `/leave` route does not exist until CHAT-7** — so
  this commit either lands the two session routes ahead of the controller, or renders the link
  without a route and defers it. Preferred: defer the Leave link to CHAT-7 and land only the layout
  structure here.
- Test: none of its own; existing tests must stay green.

**2. `feat: add chat UI components`**

- `ChatterheadWeb.ChatComponents` with:
  - `<.status_dot online?={...} />` — a small filled/hollow indicator with an accessible label
  - `<.roster entries={...} counts={...} current_user_id={...} />` — grouped "Online (n)" /
    "Offline (n)" sections, each entry `id={"roster-user-#{entry.id}"}` with a stable
    `data-online` attribute for tests
  - `<.message message={...} current_user_id={...} />` — author, absolute `HH:MM` timestamp with the
    full timestamp in a `title`, body
  - `last_seen_label/1` — `nil` → the copy chosen in CHAT-4 open question 3; otherwise a relative
    string ("2m ago", "1h ago", "yesterday")
- Import the module into `html_helpers` in
  [chatterhead_web.ex](../lib/chatterhead_web.ex#L78) so both LiveViews get it without aliasing
- Tests (`test/chatterhead_web/components/chat_components_test.exs`, `async: true`) using
  `Phoenix.LiveViewTest.render_component/2`: online and offline entries render distinguishable
  markup; the current user is marked; `last_seen_label/1` handles nil, seconds, minutes, hours, days.

## Notes

**Background — the AGENTS.md tension.** The brief says aesthetics are not the focus; this repo's
inherited `AGENTS.md` says "world-class UI" (line 41) and "always manually write your own
tailwind-based components instead of using daisyUI" (line 33) while also saying "**always** use the
imported `<.input>` component" (line 17) — which is itself built on daisyUI classes. Those two rules
already contradict each other; the tension is inherited, not created here. **D11 resolves it**: build
a purpose-built chat layout on top of the components that ship, rather than a from-scratch design
system. Note the reasoning in the README so the choice reads as a decision rather than an oversight.

**Every element that a test will select needs a stable DOM id.** AGENTS.md's LiveView test guidance
is explicit that assertions go through `element/2` and `has_element?/2`, never raw HTML matching.
Naming convention in §6.3.

**HEEx escapes by default.** Message bodies are user input rendered verbatim; never reach for `raw/1`.
An escaping test is worth writing once, in CHAT-9, against a body containing `<script>`.

**Relative timestamps do not tick.** A LiveView only re-renders on a change, so "2m ago" stays "2m
ago" until the next roster event. Accepted (a `Process.send_after/3` refresh timer is a real option
and deliberately out of scope). Message timestamps are absolute for exactly this reason.

**Open questions**

1. **Message grouping** — should consecutive messages from one author collapse into a group with a
   single header? Better-looking and materially more code, and it interacts badly with streams:
   grouping depends on the *previous* item, which a stream cannot see, so it would have to be
   computed server-side and re-computed when a message is prepended.
2. **Avatars** — initials in a coloured circle derived from the name hash? Cheap and it helps scanning.
3. **Own-message styling** — right-aligned bubbles (chat-app convention) or a uniform left-aligned
   log (easier to scan, and honest about this being one shared room)?
4. Should the header show a live "n online" count, or is the roster enough?

## Acceptance criteria

- [ ] No page renders the Phoenix logo, version badge, or the generated marketing links.
- [ ] `<.roster>` renders online users above offline users, each with a distinguishable status
      indicator and a stable per-user DOM id.
- [ ] `<.message>` renders the author, the body, and a timestamp, and escapes HTML in the body.
- [ ] `last_seen_label/1` returns a sensible string for `nil` and for timestamps seconds, minutes,
      hours, and days in the past.
- [ ] The component test file runs `async: true` and needs neither a database nor a socket.
- [ ] `mix precommit` is clean; no unused-import or unused-alias warnings from the layout rewrite.

---

# CHAT-7 — Identity, routing, and the join flow

## Summary

Everything that turns a visitor into a named participant: the session plug and `on_mount` hooks that
carry `%Scope{}` through the request and the socket, the controller that writes the session cookie,
the router with both live routes inside one `live_session`, the lobby with its join form, and a
guarded room view. After this ticket the app is navigable end to end — the room is just still empty.

## Commits

**1. `feat: add UserAuth scope hooks for controllers and LiveViews`**

- `ChatterheadWeb.UserAuth`:
  - `fetch_current_scope/2` — a plug reading `get_session(conn, :user_id)`, loading the user, and
    assigning `:current_scope` (possibly `nil`)
  - `on_mount(:mount_current_scope, _params, session, socket)` — same, for LiveViews, via
    `assign_new/3`
  - `on_mount(:require_joined_user, ...)` — when there is no scope, `put_flash` and
    `{:halt, redirect(socket, to: ~p"/")}`
  - `log_in_user(conn, user)` — `renew_session/1` then `put_session(:user_id, user.id)`
  - `log_out_user(conn)` — `renew_session/1` and clear
- Add `plug :fetch_current_scope` to the `:browser` pipeline in
  [router.ex](../lib/chatterhead_web/router.ex#L4)
- Tests (`test/chatterhead_web/user_auth_test.exs`, `async: true`): the plug assigns a scope for a
  session with a `user_id` and `nil` otherwise; a session pointing at a deleted user yields `nil`
  rather than raising; `log_in_user/2` renews the session id; the `:require_joined_user` hook halts
  and redirects.
- `~p"/"` already resolves (the scaffold's `get "/"` route still exists at this point), so this
  commit compiles standalone.

**2. `feat: add join flow with lobby and room routes`**

- Router — replace `get "/", PageController, :home` with:
  ```elixir
  post "/join", SessionController, :create
  delete "/leave", SessionController, :delete

  live_session :current_scope, on_mount: [{ChatterheadWeb.UserAuth, :mount_current_scope}] do
    live "/", LobbyLive, :index
  end

  live_session :joined, on_mount: [
    {ChatterheadWeb.UserAuth, :mount_current_scope},
    {ChatterheadWeb.UserAuth, :require_joined_user}
  ] do
    live "/room", RoomLive, :show
  end
  ```
- `ChatterheadWeb.SessionController`:
  - `create/2` receives **`%{"user" => %{"name" => name}}`**, not a bare `name`. The form is built
    from `Accounts.change_user/2`, a changeset over `%User{}`, so `to_form/2` derives `as: :user` and
    nests the params. Pattern-match the nested shape in the function head.
  - `create/2` — `Accounts.join(name)` → `log_in_user/2` → `redirect(to: ~p"/room")`; on
    `{:error, changeset}`, flash the first error message and redirect back to `~p"/"`
  - `delete/2` — `log_out_user/1` → `redirect(to: ~p"/")`
- `ChatterheadWeb.LobbyLive`:
  - `mount/3` assigns `Accounts.list_users/0` and a form from `Accounts.change_user/2`
  - the join form is a **plain full-page POST with live validation**:
    ```heex
    <.form for={@form} id="join-form" action={~p"/join"} phx-change="validate">
      <.input field={@form[:name]} type="text" label="Your name" required />
      <.button>Join the chat</.button>
    </.form>
    ```
    Setting `:action` makes `<.form>` emit the CSRF token automatically. `phx-change` gives immediate
    feedback; there is **no** `phx-submit`, so submitting performs a real POST that can set a cookie.
  - `handle_event("validate", ...)` re-assigns the form with `action: :validate`
  - renders every user from `Accounts.list_users/0` — all offline for now; CHAT-8 makes it live
- `ChatterheadWeb.RoomLive` — minimal: renders the shell and the current user's name. CHAT-9 fills it in.
- Add the "Leave" link to `Layouts.app`, now that `~p"/leave"` resolves.
- Delete `page_controller.ex`, `page_html.ex`, `page_html/home.html.heex`, and
  `test/chatterhead_web/controllers/page_controller_test.exs`.
- **Extend `ConnCase` in this commit.** As generated it imports only `Plug.Conn` and
  `Phoenix.ConnTest` — there is no `Phoenix.LiveViewTest` import and no session helper, and no
  `phx.gen.auth` scaffolding to inherit one from. Add `import Phoenix.LiveViewTest` to the `using`
  block (every LiveView test file from here on needs it) and a `log_in(conn, user)` helper built on
  `Phoenix.ConnTest.init_test_session/2`.
- Tests:
  - `session_controller_test.exs` — a valid name creates the user, sets `:user_id`, and redirects to
    `/room`; an existing name reuses the row; a blank name redirects to `/` with an error flash and
    creates nothing; `DELETE /leave` clears the session
  - `lobby_live_test.exs` — `/` renders `#join-form` and every seeded user; `phx-change` with a blank
    name shows a validation error
  - `room_live_test.exs` — `/room` without a session redirects to `/`; with a session it renders

## Notes

**Background — why a controller at all.** A LiveView runs over a WebSocket and cannot set a cookie.
That single fact is what makes the join a plain form POST (doc 01 §4 Axis 4). The payoff is that
identity survives a refresh, the back button, and a second tab — which is what makes the "open two
browser windows" demo behave sanely.

**Why this commit is larger than the others.** The router, the controller, and both LiveViews are
mutually referential: `SessionController.create/2` redirects to `~p"/room"`, `LobbyLive`'s form posts
to `~p"/join"`, and verified routes raise a **compile-time warning** for any `~p` path with no
matching route — which `mix compile --warnings-as-errors` turns into a build failure. Splitting this
further would mean committing a state that does not build. Atomic means self-contained, not minimal:
the unit of work here is "the join flow", and it is genuinely indivisible.

**Two `live_session` blocks, not one.** `on_mount` hooks are per-`live_session`, and only `/room`
requires a joined user. Note that navigating between two different `live_session`s forces a full page
load rather than a socket-preserving `navigate` — acceptable here, since joining is a full POST
anyway. A single `live_session` with the guard inside `RoomLive.mount/3` is the alternative; it is
less declarative.

**`renew_session/1` before writing the session** is standard session-fixation hygiene, copied from
what `phx.gen.auth` generates. Cheap, and its absence is the kind of thing a reviewer notices.

**The controller's error path loses changeset detail** — it can only flash a string, because a
controller cannot re-render a LiveView. The `phx-change` validation on the form makes that path rare;
it is a fallback for a direct POST, not the primary UX.

**Open questions**

1. **Should an already-joined visitor hitting `/` be redirected straight to `/room`?** Convenient, but
   it makes the lobby unreachable without leaving first — and A1 asks for a landing page that lists
   all users. Recommendation: do not redirect; show the roster with a "Back to the room" link instead.
2. **Session lifetime** — the endpoint's default session config has no `max_age`. Should a join
   expire?
3. **`/room` for a non-joined visitor** — redirect to `/` with a flash (specified) or return 404?
   Redirect is friendlier and matches `phx.gen.auth` conventions.
4. Should `LobbyLive` prefill the name field from an existing session so rejoining is one click?

## Acceptance criteria

- [ ] `/` renders the join form and a list of every persisted user.
- [ ] Submitting a new name creates the user, sets `:user_id` in the session, and lands on `/room`.
- [ ] Submitting an existing name (in any casing) reuses that user and creates no new row.
- [ ] Submitting a blank name returns to `/` with an error flash and creates nothing.
- [ ] Refreshing `/room` keeps you in the room; a second browser tab is the same user.
- [ ] Visiting `/room` with no session redirects to `/`.
- [ ] `DELETE /leave` clears the session and returns to `/`.
- [ ] The generated Phoenix landing page and its controller, view, template, and test are gone.

---

# CHAT-8 — Lobby roster with live presence

## Summary

Make the lobby's user list live: seed it from the database plus a presence snapshot, then keep it
current from the semantic presence events. This is where requirements A1, A2, and A8 become
observable.

## Commits

**1. `feat: show live online status on the lobby`**

Uses `eventually/2` and `drain_presence_fetchers/0` from CHAT-4 commit 1, and `log_in/2` from CHAT-7
commit 2. Both already exist; this ticket adds no test support of its own.

- `LobbyLive.mount/3`, guarded by `connected?(socket)`:
  1. `Phoenix.PubSub.subscribe(Chatterhead.PubSub, Presence.events_topic())`
  2. **then** snapshot `Presence.online_users/0`
  3. `Roster.build(Accounts.list_users(), online)` into `@roster`
- On the dead render (not connected), build the roster with an empty online map so the first paint is
  correct HTML rather than a blank list.
- `handle_info({:user_online, payload}, socket)` → `Roster.mark_online/2`
- `handle_info({:user_offline, payload}, socket)` → `Roster.mark_offline/2`
- Render `<.roster entries={Roster.entries(@roster)} counts={Roster.counts(@roster)} />`
- Tests (`lobby_live_test.exs`, **`async: false`**): seeded users render as offline; tracking a
  spawned process makes that user render as online (wrapped in `eventually/2`); killing it flips them
  back to offline; a user tracked but not in the database still appears.

## Notes

**Subscribe before snapshotting — the order is load-bearing.** If you snapshot first and subscribe
second, any join or leave occurring in between is lost forever: the diff stream never replays. In the
specified order the worst case is receiving an event you already have in the snapshot, and both
`mark_online/2` and `mark_offline/2` are idempotent, so a duplicate is a no-op. This is a two-line
detail that produces a bug class that only appears under load.

**`mount/3` runs twice** — once for the dead HTTP render, once over the WebSocket. Subscribing on the
dead render would leak a subscription from a process that is about to exit. `connected?/1` guards it.

**The lobby does not track presence**, it only observes it. A visitor at `/` has not joined and has no
identity to track; a joined user browsing the lobby is deliberately not counted as in the room. This
is CHAT-4 open question 2 surfacing in the UI — whichever way it is decided, the README must say so.

**Presence is not sandboxed.** Presence and PubSub are application-wide processes and
`Ecto.Adapters.SQL.Sandbox` isolation does not reach them. Any test that tracks presence must be
`async: false`; this scaffold's `DataCase.setup_sandbox/1` uses `shared: not tags[:async]`
([data_case.ex:39](../test/support/data_case.ex#L39)), so `async: false` also puts the Repo in shared
mode — which is what lets CHAT-4's unowned `last_seen_at` task find a connection with no explicit
`Sandbox.allow/3`.

**Open questions**

1. Should the lobby show a "Back to the room" link when `@current_scope` is set (CHAT-7 open
   question 1)?
2. Should the lobby's own list of users refresh when a brand-new user is created by someone else?
   As specified, `Roster.mark_online/2` inserts unknown users, so a new joiner appears the moment they
   are tracked — no extra query and no extra topic. Is that sufficient, or should `Accounts` broadcast
   a `{:user_created, user}` event so the list is right even before that user's socket connects?
3. Is the presence snapshot worth wrapping in a `Presence` helper (`online_users/0` already does this)
   or should the LiveView call `Presence.list/1` directly? The helper is specified; it keeps
   Presence's `%{key => %{metas: [...]}}` shape out of the LiveView.

## Acceptance criteria

- [ ] With nobody in the room, `/` lists every seeded user as offline.
- [ ] When another client is in the room, `/` lists that user as online without a refresh.
- [ ] When that client disconnects, `/` flips them to offline without a refresh or any user action.
- [ ] A lobby opened *after* someone is already online shows them as online immediately (snapshot works).
- [ ] The lobby never receives a raw `presence_diff` message.
- [ ] Lobby presence tests pass repeatedly (`mix test --repeat-until-failure 20`) with no flakes.

---

# CHAT-9 — Room: message history, streaming, and composition

## Summary

The room's message pane: the most recent page of history streamed on mount, live fan-out of new
messages to every connected client, a compose form, and the scroll behaviour that makes it usable.
This closes A5 (partially — CHAT-10 completes it), A7, and the "reactive UI updates" objective.

## Commits

**1. `feat: stream message history in the room`**

- `RoomLive.mount/3`:
  - `{messages, more?} = Chat.list_recent()`
  - `stream(socket, :messages, messages)`
  - assign `@more_history?` and `@oldest_cursor` (from the first message, or `nil` for empty history)
  - subscribe to `Chat.topic()` when `connected?(socket)`
- `handle_info({:new_message, message}, socket)` → `stream_insert(socket, :messages, message)`
  (default `at: -1` **appends** — see Notes)
- Template (commit 3 adds `phx-hook` and the scroll classes to this same element):
  ```heex
  <div id="messages" phx-update="stream">
    <div class="hidden only:block">No messages yet. Say something.</div>
    <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
      <.message message={message} current_user_id={@current_scope.user.id} />
    </div>
  </div>
  ```
- Tests (**`async: false`**): seeded history renders oldest-first; a message broadcast on
  `Chat.topic()` appears without any user action; a body containing `<script>` renders escaped.

**2. `feat: add message composition to the room`**

- Form assign from `Chat.change_message/2`, rendered as
  `<.form for={@form} id="message-form" phx-submit="send" phx-change="validate">`
- `handle_event("send", %{"message" => params}, socket)`:
  - `Chat.send_message(socket.assigns.current_scope, params)`
  - on success, reset the form to a fresh changeset — and **do not** `stream_insert` here; the
    message arrives via the PubSub subscription like everyone else's
  - on error, re-assign the form with `action: :validate` so the error renders
- Tests: submitting persists a row and renders it for the sender; a blank body renders an error and
  persists nothing; the form clears after a successful send.

**3. `feat: keep the room scrolled to the newest message`**

- Colocated hook (AGENTS.md requires colocated hooks over `<script>` tags, and the name must start
  with `.`) placed **directly on the `phx-update="stream"` element**, which is also the scroll box:
  ```heex
  <div
    id="messages"
    phx-update="stream"
    phx-hook=".MessageList"
    class="flex-1 overflow-y-auto"
  >
    <div class="hidden only:block">No messages yet. Say something.</div>
    <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
      <.message message={message} current_user_id={@current_scope.user.id} />
    </div>
  </div>
  ```
- **Do not put the hook on a wrapper around the stream container.** A hook's `updated()` fires only
  when *the hooked element itself* is visited by the patch as a changed `from`/`to` pair — LiveView
  gates it on `!fromEl.isEqualNode(toEl)` in `triggerBeforeUpdateHook`, records the id in
  `updatedHookIds`, and only then calls `__updated()`
  (`deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js:5003`, `:5047`, `:5064`). A hook on an
  ancestor of the stream container is not guaranteed to be visited on every `stream_insert`,
  particularly when the patch is scoped such that the ancestor becomes the target container
  (`childrenOnly: true` skips the container itself). Putting the hook on the stream element is the
  conventional pattern and removes the question entirely.
- Hook behaviour:
  - `mounted()` — scroll to the bottom
  - `beforeUpdate()` — record `scrollHeight` and whether the viewport is within a few pixels of the
    bottom
  - `updated()` — if it was at the bottom, scroll to the bottom again; otherwise leave the position
    alone so a user reading history is not yanked away
- **No `phx-update="ignore"`** — the hook reads and sets `scrollTop` but does not manage the DOM
  contents, so LiveView must keep patching it. (This was the original reason for wanting a separate
  wrapper element; it was never a real constraint.)
- Test: assert the hook is wired (`has_element?(view, "#messages[phx-hook='.MessageList']")`).
  The scroll behaviour itself is JavaScript in a browser and is verified manually; say so in the
  commit message rather than implying coverage that does not exist.

## Notes

**`stream_insert/4` defaults to `at: -1`, which appends.** AGENTS.md's stream cheatsheet (line 227)
labels `at: -1` as "prepend" — **it is wrong**. New messages append; `at: 0` is what prepends, which
is what CHAT-10 needs. Do not let the cheatsheet "correct" this.

**Why a stream and not an assign.** An unbounded `@messages` list in socket assigns is a memory leak
per connection. Streams keep the server-side assign bounded regardless of message count. Note
honestly in the README that streams bound *server* memory — the rendered DOM still holds whatever has
been sent, which is what the windowing in CHAT-10 addresses on the client side.

**Do not rely on `stream`'s `:limit` option to cap the list**: it is not enforced on the first
`mount/3` render. The fix is always to load fewer rows.

**Re-stream when an assign changes what a streamed item renders.** Streams do not re-render from
assigns. Nothing in this ticket does that (`@current_scope` is fixed for the life of the socket), but
any future per-message state — editing, reactions, read receipts — would require a `stream_insert/4`
of the affected item.

**The sender sees their own message through PubSub.** Resisting a local echo is what guarantees every
client renders the same list in the same order from the same code path.

**Open questions**

1. **`input` or `textarea` for the composer?** A textarea supports multi-line messages but needs a JS
   hook for Enter-to-send / Shift+Enter-for-newline. A single-line input is zero JS and matches the
   brief's scope. Recommendation: input.
2. Should the composer clear optimistically on submit, or only after the server accepts? Clearing
   optimistically feels faster; clearing on success means a rejected message is not lost.
3. Should `@more_history?` and `@oldest_cursor` be maintained here, or introduced in CHAT-10 with the
   control that uses them? Specified here so the mount query has one shape across both tickets.
4. Is a "N new messages below" affordance wanted when the user has scrolled up? Nice, and it needs a
   counter assign because streams cannot be counted.

## Acceptance criteria

- [ ] Opening `/room` shows the most recent page of history, oldest at the top.
- [ ] With no messages at all, the room shows an empty state.
- [ ] Sending a message persists it and renders it for the sender.
- [ ] The same message appears in another already-open client with no refresh.
- [ ] The composer clears after a successful send.
- [ ] A blank or whitespace-only message is rejected with a visible error and persists nothing.
- [ ] A message body containing HTML renders as text, not markup.
- [ ] The message pane is scrolled to the newest message on load and stays pinned while at the bottom.

---

# CHAT-10 — Room: load older messages

## Summary

Complete requirement A5 — *all* past messages must be reachable — with keyset pagination on
`{inserted_at, id}`, plus the scroll-position preservation that keeps prepending from being
disorienting.

## Commits

**1. `feat: load older messages with keyset pagination`**

- Render a `#load-older` control above the stream, only when `@more_history?`
- `handle_event("load_older", _params, socket)`:
  ```elixir
  {older, more?} = Chat.list_before(socket.assigns.oldest_cursor)

  socket = stream(socket, :messages, Enum.reverse(older), at: 0)
  ```
  then update `@oldest_cursor` from `List.first(older)` and `@more_history?` from `more?`
- **Why the reverse.** `Chat.list_before/2` returns oldest-first (CHAT-3). Inserting at position 0
  repeatedly pushes each new item above the previous one, so the *last* item inserted ends up on top.
  Feeding the page newest-first therefore leaves the oldest message at the top, which is correct.
  Getting this backwards silently renders the older page in reverse order — a bug that looks like
  a sorting problem in the query.
- **This is the documented idiom, not a trick.** `stream/4`'s own docs spell out that inserting
  multiple items at `at: 0` displays them in reverse, and prescribe `Enum.reverse/1` as the fix
  (`deps/phoenix_live_view/lib/phoenix_live_view.ex:1866-1876`). One `stream/4` call replaces an
  `Enum.reduce` over `stream_insert/4` and behaves identically.
- Guard against a `nil` cursor (empty history) and against a double-click while a load is in flight.
- Tests (**`async: false`**): with `page_size + 10` seeded messages, the initial render shows
  `page_size` and `#load-older` is present; clicking it renders the remaining 10 **above** the
  existing ones and hides the control; clicking when history is exactly one page shows no control at
  all; inserting new messages between two loads causes neither a duplicate nor a skip — the property
  that offset pagination would fail.

**2. `feat: preserve scroll position when older messages load`**

- Extend the `.MessageList` hook — which is on `#messages` itself (CHAT-9), so it is guaranteed to be
  visited when the stream changes: in `updated()`, when the viewport was *not* at the bottom before
  the patch, apply `el.scrollTop += el.scrollHeight - previousScrollHeight`. That keeps the message the
  user was reading in place while content is inserted above it, and it needs no server-side event —
  the height delta is sufficient to distinguish a prepend from an append.
- Test: hook wiring is already asserted in CHAT-9; the behaviour is verified manually. Say so.

## Notes

**Background.** Requirement A5 is "show **all** past chat messages". D8 chose windowed loading, which
satisfies A5 only because this control is actually built. Deferring it to a stretch goal would ship
something that fails the requirement — that is the whole reason it is a first-class ticket.

**Keyset is the point, not an optimisation.** Under a live chat, `OFFSET` is defined against a result
set that shifts on every insert, so paging backwards duplicates or skips messages. The
`(inserted_at, id) < (cursor)` predicate is anchored to a row. The `[:inserted_at, :id]` index from
CHAT-3 makes it an index range scan whose cost is independent of how far back you page. This is worth
two sentences in the README.

**Open questions**

1. **Button or `phx-viewport-top`?** LiveView ships a `phx-viewport-top` binding that fires when the
   top of the container scrolls into view — the idiomatic infinite-scroll approach, and a nicer
   experience. A button is deterministic in tests and makes the pagination visible to a reviewer.
   Recommendation: **button**, with `phx-viewport-top` named in the README as the production upgrade.
   If infinite scroll is chosen instead, the tests must drive it via `render_hook/3`.
2. Should the control be disabled (rather than hidden) while a page is loading, to make the in-flight
   state visible? `phx-disable-with` handles this with no extra state.
3. Should loading older messages be capped (say, five pages) before suggesting a search instead?
   Out of scope; a README scale note at most.

## Acceptance criteria

- [ ] With more than one page of history, `#load-older` is visible on mount.
- [ ] Clicking it prepends exactly the preceding page, in correct chronological order, above the
      existing messages.
- [ ] Repeated clicks walk back through history with no duplicated and no skipped message.
- [ ] The control disappears once the oldest message is loaded.
- [ ] With one page or less of history, the control never appears.
- [ ] Messages arriving while the user is paged back still append at the bottom.
- [ ] The message the user is reading stays visually in place when older messages load above it.

---

# CHAT-11 — Room: presence tracking and the live roster

## Summary

Track the current user's connection as a presence and render the live roster in the room sidebar.
This is the ticket that makes A8 ("presence managed dynamically") true — closing the tab flips you
offline with no user action and no polling, because process lifecycle does the work.

## Commits

**1. `feat: track presence and render the live roster in the room`**

- `RoomLive.mount/3`, guarded by `connected?(socket)`, in this order:
  1. `Phoenix.PubSub.subscribe(Chatterhead.PubSub, Presence.events_topic())`
  2. `Presence.track_user(self(), socket.assigns.current_scope.user)`
  3. snapshot `Presence.online_users/0` and `Roster.build(Accounts.list_users(), online)`
- `handle_info/2` clauses for `{:user_online, _}` and `{:user_offline, _}`, exactly as in CHAT-8 —
  extract the two clauses into a shared helper if the duplication is more than trivial, but do not
  build a LiveComponent for it (AGENTS.md: avoid LiveComponents without a strong specific need)
- Render `<.roster>` in the sidebar of the two-pane layout, with `current_user_id` so the current
  user is marked
- **No `terminate/2`.** Untracking on process exit is automatic; writing manual cleanup here is a
  misunderstanding of how `Phoenix.Tracker` works.
- Tests (`room_live_test.exs`, **`async: false`**):
  - the current user appears in their own roster as online
  - a second `live/2` connection for a different user appears in the first's roster (wrapped in
    `eventually/2`)
  - closing that second connection flips them to offline in the first's roster
  - **multi-tab**: two connections for the *same* user, close one, the user stays online
  - `on_exit` drains the presence fetchers

## Notes

**`mount/3` runs twice** — dead render, then WebSocket. Tracking on the dead render would register a
process that is about to exit, producing a phantom online user that disappears a moment later.
`connected?/1` is not optional here.

**Subscribe before tracking before snapshotting.** Subscribing first means your own join event cannot
be missed; tracking before the snapshot means the snapshot already contains you, so the roster is
correct on the very first paint. Every handler is idempotent, so any overlap is harmless.

**Multi-tab correctness is decided in CHAT-4**, but it is only *observable* here — which is why the
two-connections-one-user test lives in this ticket.

**`Phoenix.Tracker` is eventually consistent.** Asserting with a bare `render/1` immediately after a
second connection mounts will pass on a fast local machine and flake in CI. Every cross-connection
presence assertion goes through `eventually/2` (CHAT-4). PubSub message fan-out is **not** subject to
this — the caveat is specific to presence.

**Open questions**

1. Should join and leave produce ephemeral "alice joined" lines in the message stream? Visible and
   satisfying, but they are not persisted messages, so they would need a separate stream or a
   synthetic struct — and they would not exist for a client that mounts later, which is a subtle
   inconsistency. Recommendation: no, and say why in the README.
2. Should the roster be clickable (a future DM or profile affordance) or is it purely informational?
   Informational, as specified.
3. Should the room show its own "n online" in the header, or is the roster's group count enough?
   (Same question as CHAT-6 open question 4 — answer it once.)

## Acceptance criteria

- [ ] Entering the room makes the current user appear as online in their own roster and in every
      other connected client's roster.
- [ ] Closing the browser tab flips that user to offline everywhere, with no user action and no polling.
- [ ] A user open in two tabs stays online when one tab closes, and goes offline when the second closes.
- [ ] The roster shows every persisted user, including those who have never been online.
- [ ] Offline users show a last-seen label that reflects when they actually left.
- [ ] A client that mounts after others are already online shows them as online immediately.
- [ ] `RoomLive` has no `terminate/2` callback.
- [ ] Room presence tests pass repeatedly (`mix test --repeat-until-failure 20`) with no flakes.

---

# CHAT-12 — Multi-client verification

## Summary

The tests that prove the feature rather than the units: two simultaneous LiveView connections
exchanging messages and observing each other's presence. Everything up to here is verified in
isolation; this ticket verifies the assembly.

## Commits

**1. `test: verify messages fan out across simultaneous clients`**

- `test/chatterhead_web/live/room_integration_test.exs`, **`async: false`**
- Two connections, each with its own session via `init_test_session/2` and the CHAT-8 `log_in/2` helper
- Send from connection A via `render_submit/2`; assert it renders in connection B
- Assert it renders in A too — proving the no-local-echo path
- Assert ordering: three messages sent alternately from A and B render in the same order in both

**2. `test: verify presence across simultaneous clients and tabs`**

- Connection A is in the room; connect B; assert B appears in A's roster (`eventually/2`)
- Disconnect B; assert B flips to offline in A's roster with a `last_seen_at` label
- Connect B twice (same user, two sockets); close one; assert A still shows B online; close the
  second; assert A shows B offline exactly once
- Assert a brand-new user — created by B's join, unknown to A at mount time — appears in A's roster

**3. `test: verify history loading across a live conversation`**

- Seed more than one page; open A; have B send new messages; page A backwards with `#load-older`
- Assert no message is duplicated or missing across the combined view — the keyset property under
  concurrent writes

## Notes

**Background.** Doc 01 §9 calls the two-connection test "the test that proves the feature". A reviewer
reading the suite will look for it specifically; it is the difference between "the functions work"
and "the app works".

**Why this is a separate ticket rather than tests distributed into CHAT-9 and CHAT-11.** Unit and
single-client LiveView tests ship with the code that they test — that rule holds throughout this plan.
These scenarios are different: they can only exist once messages, presence, and pagination are all
assembled, and they are the artefact a reviewer opens first. Keeping them in one named file makes
them findable.

**Sandbox mode.** Everything here is `async: false`, which puts the Repo in shared mode
([data_case.ex:39](../test/support/data_case.ex#L39)) — necessary for both connections and for the
unowned `last_seen_at` task to see the same connection.

**Drain fetchers in `on_exit`.** Even with no `fetch/2` implemented, draining
`Presence.fetchers_pids/0` at the end of every presence test is the documented pattern and keeps
process leakage from bleeding across tests.

**Open questions**

1. Is an N-client test (five or ten simultaneous connections) worth adding, or does two prove the
   property? Two proves fan-out; more mostly proves the test harness.
2. Should there be a test that a message sent while a client is *reconnecting* still arrives? That is
   really a test of LiveView's own reconnect behaviour, not of this app.
3. Should the suite gain a `@tag :integration` so these can be excluded from a fast local loop?

## Acceptance criteria

- [ ] A message sent from one connection renders in a second connection with no user action.
- [ ] The sender sees their own message via the same broadcast path, not a local echo.
- [ ] Interleaved messages from two clients render in identical order in both.
- [ ] A user joining is reflected in an already-open client's roster.
- [ ] A user leaving is reflected in an already-open client's roster.
- [ ] Multi-tab presence behaves correctly across two real LiveView connections.
- [ ] Paging backwards while another client is sending produces no duplicate and no missing message.
- [ ] `mix test --repeat-until-failure 20` on this file is green.

---

# CHAT-13 — README

## Summary

The submission's front door: setup that works on a machine that has never seen this repo, the
assumptions the brief asks to be documented, and the architecture rationale — including what was
deliberately **not** built, which doc 01 §1 notes is graded alongside the code.

## Commits

**1. `docs: add README with setup, assumptions, and architecture`**

Replace the generated `README.md` with:

- **What it is** — one paragraph, and a note that it is a take-home exercise
- **Quickstart** — `docker compose up -d --wait`, `mix setup`, `mix phx.server`, open
  `localhost:4000`; then "open a second browser (or a private window) to see presence and fan-out"
- **Running without Docker** — the credentials `config/dev.exs` and `config/test.exs` expect, and how
  to change them
- **Running the tests** — `mix test`, and `mix precommit` for the full gate
- **Architecture** — the module map from §2, the three topics from §3.1, and the two paths drawn out:
  - message: `RoomLive` → `Chat.send_message/2` → `Repo.insert` → `PubSub.broadcast` → every
    subscriber's `handle_info` → `stream_insert` (including the sender's)
  - presence: `RoomLive.mount` → `Presence.track_user/2` → tracker diff → `handle_metas/4` →
    semantic `local_broadcast` → every subscriber's roster update, plus a supervised task writing
    `last_seen_at`
- **Design decisions**, each one or two sentences:
  - `Phoenix.Presence` over a hand-rolled monitor GenServer — and the honest single-node caveat
  - the presence client as a documented extension point, and what it buys (`last_seen_at`, LiveViews
    decoupled from Presence's data shape)
  - no room process — with the conditions under which one *would* earn its keep (typing indicators,
    per-room rate limiting, an in-memory ring buffer, many rooms with skewed traffic)
  - `citext` over a `lower(name)` index, and the privilege trade-off
  - `:utc_datetime_usec` on messages, and the same-second reordering bug it prevents
  - keyset over offset pagination
  - broadcasting from the context, not the LiveView
  - no local echo
  - streams for messages, a plain assign for the roster
- **Assumptions** — doc 01 §10, plus every open question this plan resolved during implementation:
  one global room; a name is an unverified identity claim (a deliberate consequence of "no
  authentication required", not an oversight); names unique case-insensitively, trimmed, bounded;
  "online" means present in the room; no edit, delete, typing indicators, read receipts, or attachments;
  ordering by database timestamp, not client clock; single-node in development
- **Known limitations** — a tracker crash on a single node loses local presence state and does not
  re-track live LiveViews; relative "last seen" labels do not tick; the full DOM cost of loaded history
- **Show your work** — point at [`docs/01-architecture-options.md`](01-architecture-options.md) and
  this plan as the decision trail, and name `AGENTS.md` as the AI instructions file the brief
  encourages submitting

## Notes

**Background.** The brief asks for setup instructions, assumptions, and a short architecture
description, and separately says "we want you to show how you arrived at the final product". The two
docs in `docs/` are that trail; the README is what makes them findable.

**The rationale is graded, not just the code.** Doc 01 §1 flags that the things deliberately not built
count. The "no room process, and here is when I would build one" paragraph is doing more work than any
other paragraph in the file.

**Keep it honest.** If any acceptance criterion in this plan was relaxed, say which and why. A README
that overstates is worse than one that admits a gap.

**Open questions**

1. Include a screenshot or a short GIF of two windows side by side? It communicates the whole feature
   in one image, and it adds a binary to the repo.
2. Note the actual time spent? The brief suggests ~2 hours and this plan deliberately exceeds it
   (doc 01 §11 question 3). Stating the real number and the reason is more credible than silence.
3. Should `docs/00-brief.md` be added after all? Doc 01 §1 flags that its requirement decoding is an
   unverified paraphrase until the brief is in the repo. Currently **not** planned.
4. Should the README carry the acceptance-criteria table (A1–A8) with a checkmark against each, as a
   self-assessment? Reviewers tend to like it; it can also read as presumptuous.

## Acceptance criteria

- [ ] A reader who has never seen the repo can go from clone to a running app using only the README.
- [ ] The setup path is verified on a clean clone with an empty Docker volume.
- [ ] Every assumption in doc 01 §10 appears, plus any added during implementation.
- [ ] The architecture section names both the message path and the presence path.
- [ ] The README states what was deliberately not built and under what conditions it would be.
- [ ] Every known limitation is stated plainly, with no overselling of multi-node resilience.
- [ ] The generated Phoenix README boilerplate is gone.

---

## 5. Requirement traceability

| Req | Criterion | Delivered by |
|---|---|---|
| A1 | Landing page lists all persisted users | CHAT-2, CHAT-7, CHAT-8 |
| A2 | Each user's online/offline status derives from live connections | CHAT-4, CHAT-5, CHAT-8 |
| A3 | Visitor enters a name to join; find-or-create; no auth | CHAT-2, CHAT-7 |
| A4 | Joined visitor enters one shared room | CHAT-7 |
| A5 | Room shows **all** past messages | CHAT-9, **CHAT-10** |
| A6 | Room shows all users and their status, live | CHAT-11 |
| A7 | New messages appear for all users and persist | CHAT-3, CHAT-9, CHAT-12 |
| A8 | Presence managed dynamically — closing a tab flips you offline | CHAT-4, CHAT-11 |
| — | OTP understanding | CHAT-4 (presence client, supervised tasks, supervision wiring) + CHAT-13 rationale |
| — | Design clarity / show your work | doc 01, this plan, CHAT-13 |

---

## 6. Global conventions

### 6.1 Commit messages

`type: imperative summary` — `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `ci`. The body
explains *why*, not what; the diff covers what. Every commit compiles with
`--warnings-as-errors` and leaves `mix test` green.

### 6.2 Test async policy

| Kind | Setting |
|---|---|
| Pure modules (`Roster`, `ChatComponents`, `Scope`) | `async: true`, no database |
| Context tests (`Accounts`, `Chat`) | `async: true` |
| `Accounts.join/1` concurrency test — **its own file** | `async: false` (spawned tasks need shared-mode sandbox) |
| Anything touching `Presence` | **`async: false`**, always |
| LiveView tests for `LobbyLive` / `RoomLive` | `async: false` (they observe presence) |

`async` is a **module-level** ExUnit setting — it cannot be overridden for a single test. Any test
needing shared-mode sandbox therefore needs its own file, and must not be dropped into an
`async: true` module: forcing shared mode from an async module breaks isolation for every other
module running concurrently.

Presence is a global, application-wide process; `Ecto.Adapters.SQL.Sandbox` isolation does not extend
to it. `DataCase.setup_sandbox/1` uses `shared: not tags[:async]`, so `async: false` puts the Repo in
shared mode — which is what lets CHAT-4's unowned `last_seen_at` task find a connection. Every
presence test drains `ChatterheadWeb.Presence.fetchers_pids/0` in `on_exit`.

Assertions crossing a tracker boundary use `eventually/2` (CHAT-4). Assertions crossing only a PubSub
boundary do not need it.

`ConnCase` is extended once, in CHAT-7, with `import Phoenix.LiveViewTest` and `log_in/2`; the
generated version has neither.

### 6.3 DOM id conventions

Tests select by id, never by raw HTML (AGENTS.md).

| Element | Id |
|---|---|
| Join form | `#join-form` |
| Roster container | `#roster` |
| Roster entry | `#roster-user-{id}` |
| Message stream container, scroll box, and hook host | `#messages` |
| Message item | the stream's generated dom id |
| Compose form | `#message-form` |
| Load older control | `#load-older` |

### 6.4 Rules inherited from AGENTS.md worth restating

- Always begin a LiveView template with `<Layouts.app flash={@flash} current_scope={@current_scope}>`
- `<.flash_group>` is called only from `layouts.ex`
- Forms are always driven by a `to_form/2` assign and the `<.input>` component; never pass a changeset
  to `<.form>`
- Icons via `<.icon name="hero-..." />`, never a `Heroicons` module
- Colocated hooks only, names prefixed with `.`; never a raw `<script>` in HEEx
- Programmatic fields (`user_id`, `last_seen_at`) are never `cast`
- Use `mix ecto.gen.migration` for every migration
- **Ignore** the stream cheatsheet's claim that `at: -1` prepends — it appends

---

## 7. Deliberately out of scope

Named here so they are decisions rather than omissions. CHAT-13 carries them into the README.

- Multiple rooms, room creation, DMs (adding rooms touches: `messages.room_id`, a topic per room, a
  roster scoped per room, and room routing)
- A `Chat.Room` GenServer with an in-memory buffer (doc 01 Plan C) — no correctness gain at one room,
  and it introduces a crash-recovery problem and a second place ordering can disagree with the database
- Authentication or any verification of a claimed name
- Editing, deleting, reactions, typing indicators, read receipts, attachments
- Message search
- Rate limiting
- Infinite scroll via `phx-viewport-top` (see CHAT-10 open question 1)
- A refresh timer to make relative "last seen" labels tick

## 8. Open questions carried forward

Cross-cutting questions that no single ticket owns. Decide before the ticket that first depends on
each.

1. **What does "online" mean** — present in the room (specified) or holding any joined session
   (CHAT-4 OQ2)? Affects CHAT-8, CHAT-11, and the README.
2. **Does `last_seen_at` mean "last went offline" or "last activity"** (CHAT-2 OQ2 / CHAT-4 OQ1)?
   Affects the roster copy.
3. **Page size and seeded message volume** (CHAT-2 OQ3 / CHAT-3 OQ1) — together they decide whether
   CHAT-10's control is visible in a fresh database.
4. **`%Scope{}` or bare `%User{}`** through the domain API (CHAT-3 OQ3). Pick once; it appears in
   every context signature.
5. **Elixir/OTP version pinning** (CHAT-1 OQ1) — a matrix honours `elixir: "~> 1.17"`; a single pin
   matches what was actually run.
6. **Commit the brief as `docs/00-brief.md`?** Doc 01 §1's requirement decoding is an unverified
   paraphrase until it exists. Currently not planned (CHAT-13 OQ3).
