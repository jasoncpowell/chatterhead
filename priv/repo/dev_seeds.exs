# Development-only message seeds, for eyeballing history / "load older" / scrolling.
#
#     mix run priv/repo/dev_seeds.exs
#
# NOT run by `mix setup` (which stays users-only, per docs/02-implementation-plan.md
# CHAT-2). Idempotent: it no-ops if the room already has messages.

alias Chatterhead.Accounts
alias Chatterhead.Chat.Message
alias Chatterhead.Repo

if Repo.exists?(Message) do
  IO.puts("Messages already present — skipping. Run `mix ecto.reset` first for a clean slate.")
else
  users =
    Enum.map(~w(alice bob carol dave erin), fn name ->
      {:ok, user} = Accounts.join(name)
      user
    end)

  lines = [
    "morning all",
    "hey",
    "anyone else's build failing on main?",
    "yeah CI's been flaky since last night",
    "i think it's the postgres container timing out",
    "raising the healthcheck retries fixed it for me locally",
    "ah good call",
    "PR up: #142",
    "looking now",
    "left a couple comments, small stuff",
    "addressed, thanks",
    "coffee run, anyone want anything?",
    "flat white please",
    "same",
    "back in 10",
    "did the keyset pagination land?",
    "yeah it's on staging, go try 'load older'",
    "works nicely, scroll position holds too",
    "the presence roster is next",
    "closing the tab flips you offline right?",
    "that's the idea, process lifecycle does it",
    "no heartbeat, no polling",
    "clean",
    "who's taking the room roster ticket",
    "i can grab it",
    "cool it's mostly wiring at this point",
    "the pure Roster module already does the hard part",
    "lunch?",
    "12:30 works",
    "same",
    "the noodle place or the other one",
    "noodles",
    "back",
    "that meeting could have been an email",
    "every meeting could have been an email",
    "hot take",
    "did we ever decide on session expiry",
    "no max_age for the demo, it's in the readme notes",
    "fine by me",
    "anyone reviewed the CHAT-9 PR",
    "the layout fix one? yeah approved",
    "min-h-0 strikes again",
    "flexbox's favourite footgun",
    "streams are surprisingly pleasant to work with",
    "no memory ballooning, template stays tiny",
    "the empty-state div needing an id threw me for a sec",
    "same, the docs example omits it",
    "TIL",
    "wrapping up for the day",
    "night",
    "night all",
    "one more push then i'm out",
    "green",
    "nice",
    "see you tomorrow",
    "morning (again)",
    "the eternal standup",
    "what did you do yesterday: this. what will you do today: this.",
    "blockers: flexbox",
    "relatable"
  ]

  # messages.inserted_at is :utc_datetime_usec — keep microsecond precision.
  now = DateTime.utc_now()
  count = length(lines)

  entries =
    lines
    |> Enum.with_index()
    |> Enum.map(fn {body, i} ->
      author = Enum.at(users, rem(i * 3 + 1, length(users)))
      at = DateTime.add(now, -(count - i) * 300, :second)
      %{user_id: author.id, body: body, inserted_at: at, updated_at: at}
    end)

  {n, _} = Repo.insert_all(Message, entries)
  IO.puts("Inserted #{n} messages across #{length(users)} users.")
end
